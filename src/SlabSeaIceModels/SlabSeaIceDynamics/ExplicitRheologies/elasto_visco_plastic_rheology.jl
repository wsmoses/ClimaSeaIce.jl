using Oceananigans.TimeSteppers: store_field_tendencies!
using Oceananigans.Operators

## The equations are solved in an iterative form following the mEVP rheology of
## Kimmritz et al (2016) (https://www.sciencedirect.com/science/article/pii/S1463500317300690)
#
# Where:
# uᵖ⁺¹ - uᵖ = β⁻¹ * (Δt / mᵢ * (∇ ⋅ σ + G) + uⁿ - uᵖ)
#

struct ElastoViscoPlasticRheology{S1, S2, S3, FT, U, V} <: AbstractExplicitRheology
    σ₁₁   :: S1
    σ₂₂   :: S2
    σ₁₂   :: S3
    ice_compressive_strength :: FT # compressive strength
    ice_compaction_hardening :: FT # compaction hardening
    yield_curve_eccentricity :: FT # elliptic yield curve eccentricity
    uⁿ    :: U
    vⁿ    :: V
    Δ_min :: FT # minimum plastic parameter (introduces viscous behaviour)
    substeps :: Int
end

"""
    ElastoViscoPlasticRheology(grid::AbstractGrid; 
                               ice_compressive_strength = 27500, 
                               ice_compaction_hardening = 20, 
                               yield_curve_eccentricity = 2, 
                               Δ_min = 1e-10,
                               substeps = 1000)

Constructs an `ElastoViscoPlasticRheology` object representing a "modified" elasto-visco-plastic
rheology for slab sea ice dynamics that follows the implementation of kimmritz et al (2016).
The ice strength ``Pₚ`` is parameterized as ``P★ h exp( - C ⋅ ( 1 - ℵ ))`` 


Arguments
=========
    
- `grid`: the `SlabSeaIceModel` grid

Keyword Arguments
=================
    
- `ice_compressive_strength`: parameter expressing compressive strength (in Nm²), default `27500`.
- `ice_compaction_hardening`: exponent coefficient for compaction hardening, default `20`.
- `yield_curve_eccentricity`: eccentricity of the elliptic yield curve, default `2`.
- `Δ_min`: Minimum value for the visco-plastic parameter. Default value is `1e-10`.
- `substeps`: Number of substeps for the visco-plastic calculation. Default value is `100`.
              Note that we here assume that β (the modified EVP parameter that substeps velocity)
              is equal to the number of substeps.
"""
function ElastoViscoPlasticRheology(grid::AbstractGrid; 
                                    ice_compressive_strength = 27500, 
                                    ice_compaction_hardening = 20, 
                                    yield_curve_eccentricity = 2, 
                                    Δ_min = 1e-10,
                                    substeps = 1000)
    σ₁₁ = CenterField(grid)
    σ₂₂ = CenterField(grid)
    σ₁₂ = Field{Face, Face, Center}(grid)
    uⁿ = XFaceField(grid) 
    vⁿ = YFaceField(grid) 
    FT = eltype(grid)
    return ElastoViscoPlasticRheology(σ₁₁, σ₂₂, σ₁₂,    
                                      convert(FT, ice_compressive_strength), 
                                      convert(FT, ice_compaction_hardening), 
                                      convert(FT, yield_curve_eccentricity),
                                      uⁿ, vⁿ,
                                      convert(FT, Δ_min),
                                      substeps)
end

function initialize_substepping!(model, rheology::ElastoViscoPlasticRheology)
    uⁿ = model.velocities.u
    vⁿ = model.velocities.v

    rheology.uⁿ .= uⁿ
    rheology.vⁿ .= vⁿ

    return nothing
end

function compute_stresses!(model, rheology::ElastoViscoPlasticRheology, Δt) 

    grid = model.grid
    arch = architecture(grid)

    h = model.ice_thickness
    ℵ = model.concentration

    u, v = model.velocities

    launch!(arch, grid, :xyz, _compute_modified_evp_stresses!, rheology, grid, u, v, h, ℵ, Δt)

    return nothing
end

@kernel function _compute_modified_evp_stresses!(rheology, grid, u, v, h, ℵ, Δt)
    i, j = @index(Global, NTuple)

    P★ = rheology.ice_compressive_strength
    C  = rheology.ice_compaction_hardening
    e  = rheology.yield_curve_eccentricity
    β  = rheology.substeps
    Δm = rheology.Δ_min

    # Extract internal stresses
    σ₁₁ = rheology.σ₁₁
    σ₂₂ = rheology.σ₂₂
    σ₁₂ = rheology.σ₁₂

    # Strain rates
    ϵ₁₁ =  ∂xᶜᶜᶜ(i, j, 1, grid, u)
    ϵ₁₂ = (∂xᶠᶠᶜ(i, j, 1, grid, v) + ∂yᶠᶠᶜ(i, j, 1, grid, u)) / 2
    ϵ₂₂ =  ∂yᶜᶜᶜ(i, j, 1, grid, v)

    # Center - Center variables:
    ϵ₁₂ᶜᶜᶜ = ℑxyᶜᶜᵃ(i, j, 1, grid, ϵ₁₂)

    # Ice divergence 
    δ = ϵ₁₁ + ϵ₂₂

    # Ice shear (at Centers)
    s = sqrt((ϵ₁₁ - ϵ₂₂)^2 + 4ϵ₁₂ᶜᶜᶜ^2)

    # Visco - Plastic parameter 
    # if Δ is very small we assume a linear viscous response
    # adding a minimum Δ_min (at Centers)
    Δᶜᶜᶜ = sqrt(δ^2 + (s / e)^2) + Δm
    
    # Face - Face variables
    ϵ₁₁ᶠᶠᶜ = ℑxyᶠᶠᵃ(i, j, 1, grid, ϵ₁₁)
    ϵ₂₂ᶠᶠᶜ = ℑxyᶠᶠᵃ(i, j, 1, grid, ϵ₂₂)

    # Ice divergence
    δᶠᶠᶜ = ϵ₁₁ᶠᶠᶜ + ϵ₂₂ᶠᶠᶜ

    # Ice shear
    sᶠᶠᶜ = sqrt((ϵ₁₁ᶠᶠᶜ - ϵ₂₂ᶠᶠᶜ)^2 + 4ϵ₁₂^2)

    # Visco - Plastic parameter 
    # if Δ is very small we assume a linear viscous response
    # adding a minimum Δ_min (at Centers)
    Δᶠᶠᶜ = sqrt(δᶠᶠᶜ^2 + (sᶠᶠᶜ / e)^2) + Δm

    # ice strength calculation 
    # Note: we can probably do this calculation just once since it does not change during substepping
    Pᶜᶜᶜ = @inbounds P★ * h[i, j, 1] * ℵ[i, j, 1] * exp(- C * (1 - ℵ[i, j, 1])) 
    
    # First interpolate then calculate P or the opposite?
    hᶠᶠᶜ = ℑxyᶠᶠᵃ(i, j, 1, grid, h)
    ℵᶠᶠᶜ = ℑxyᶠᶠᵃ(i, j, 1, grid, ℵ)
    Pᶠᶠᶜ = @inbounds P★ * hᶠᶠᶜ * ℵᶠᶠᶜ * exp(- C * (1 - ℵᶠᶠᶜ)) 

    # Yield curve parameters
    ζᶜᶜᶜ = Pᶜᶜᶜ / (2Δᶜᶜᶜ)
    ηᶜᶜᶜ = ζᶜᶜᶜ / e^2

    ζᶠᶠᶜ = Pᶠᶠᶜ / (2Δᶠᶠᶜ)
    ηᶠᶠᶜ = ζᶠᶠᶜ / e^2

    # σ(uᵖ)
    σ₁₁ᵖ⁺¹ = 2 * ηᶜᶜᶜ * ϵ₁₁ + ((ζᶜᶜᶜ - ηᶜᶜᶜ) * (ϵ₁₁ + ϵ₂₂) - Pᶜᶜᶜ / 2)
    σ₂₂ᵖ⁺¹ = 2 * ηᶜᶜᶜ * ϵ₂₂ + ((ζᶜᶜᶜ - ηᶜᶜᶜ) * (ϵ₁₁ + ϵ₂₂) - Pᶜᶜᶜ / 2)
    σ₁₂ᵖ⁺¹ = 2 * ηᶠᶠᶜ * ϵ₁₂

    mᵢ = @inbounds h[i, j, 1] * ℵ[i, j, 1] * 917

    # Following an mEVP formulation: α * β > (ζ / 4) * π² * (Δt / mᵢ) / Az
    # We assume here that β = substeps and calculate α accordingly
    α = ζᶜᶜᶜ / 4 * Δt / mᵢ * π^2 / Azᶜᶜᶜ(i, j, 1, grid) / β

    @inbounds σ₁₁[i, j, 1] = ((α - 1) * σ₁₁[i, j, 1] + σ₁₁ᵖ⁺¹) / α
    @inbounds σ₂₂[i, j, 1] = ((α - 1) * σ₂₂[i, j, 1] + σ₂₂ᵖ⁺¹) / α
    @inbounds σ₁₂[i, j, 1] = ((α - 1) * σ₁₂[i, j, 1] + σ₁₂ᵖ⁺¹) / α
end

@inline function x_internal_stress_divergence(i, j, grid, r::ElastoViscoPlasticRheology) 
    ∂xσ₁₁ = δxᶠᶜᶜ(i, j, 1, grid, Ax_qᶜᶜᶜ, r.σ₁₁)
    ∂yσ₁₂ = δyᶠᶜᶜ(i, j, 1, grid, Ay_qᶠᶠᶜ, r.σ₁₂)

    return (∂xσ₁₁ + ∂yσ₁₂) / Vᶠᶜᶜ(i, j, 1, grid)
end

@inline function y_internal_stress_divergence(i, j, grid, r::ElastoViscoPlasticRheology) 
    ∂xσ₁₂ = δxᶜᶠᶜ(i, j, 1, grid, Ax_qᶠᶠᶜ, r.σ₁₂)
    ∂yσ₂₂ = δyᶜᶠᶜ(i, j, 1, grid, Ay_qᶜᶜᶜ, r.σ₂₂)

    return (∂xσ₁₂ + ∂yσ₂₂) / Vᶜᶠᶜ(i, j, 1, grid)
end
