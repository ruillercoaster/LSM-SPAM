module LeafPhotosynthesisMod
using MathToolsMod
using Parameters
using Leaf


export fluxes
"Tolerance thhreshold for Ci iterations"
tol = 0.1
vpd_min = 0.1

" Just a placeholder for now"
@with_kw mutable struct fluxes{TT<:Number}
         APAR::TT = 500
         gbc::TT = 100
         gbv::TT = 100
         cair::TT = 400
         ceair::TT = 1400
         eair::TT = 1400
         je::TT = 1100
         #gs::TT = 0.0
         ac::TT = 0
         aj::TT = 0
         ai::TT = 0
         ap::TT = 0
         ag::TT = 0
         an::TT = 0
         cs::TT = 0
         #ci::TT = 0
         rd::TT = 0
         Je_pot::TT = 0
         Ja::TT = 0
         Je_red::TT = 0
         φ::TT = 0
end

struct atmos
         o2air              # Atmospheric O2 (mmol/mol)
         co2air             # Atmospheric CO2 (μmol/mol)
         eair               # Vapor pressure of air (Pa)
end

"""
    LeafPhotosynthesis(flux::fluxes, leaf::leaf_params,T::Number)

Compute net assimilation rate A, fluorescence F using biochemical model

# Arguments
- `flux::fluxes`: fluxes structure.
- `leaf::leaf_params`: leaf_params structure.
- `T::Number`: Leaf Temperature
"""
function LeafPhotosynthesis(flux::fluxes, leaf::leaf_params,T::Number)
    # Adjust rates to leaf Temperature (C3 only for now):
    setLeafT!(leaf, T)
    # Compute max PSII efficiency here (can later be used with a variable Kn!)
    if !leaf.dynamic_state
        leaf.Kn = 0.0
    end
    leaf.Kp = 4.0

    φ_PSII = leaf.Kp/(leaf.Kp+leaf.Kf+leaf.Kd+leaf.Kn)

    # Save leaf respiration
    flux.rd = leaf.rdleaf
    # Calculate potential electron transport rate (assuming no upper bound, proportional to absorbed light!):
    flux.Je_pot = 0.5 * leaf.maxPSII * flux.APAR;                          # potential electron transport rate (important for later)
    flux.Je_red = 0.5 * φ_PSII * flux.APAR;                                # Includes Kn here
    # Some bound constraint on VPD:
    flux.ceair = min(max(flux.eair, 0.03*leaf.esat), leaf.esat )

    # Electron transport rate for C3 plants
    # Actual colimited potential Je (curvature and Jmax)
    #flux.je = minimum(quadratic(leaf.θ_j, -(flux.Je_red + leaf.jmax), flux.Je_red * leaf.jmax))    # Bonan eq. 11.21
    flux.je = min(flux.Je_red,leaf.jmax)
    #flux.je = minimum(quadratic(leaf.θ_j, -(flux.Je_pot + leaf.jmax), flux.Je_pot * leaf.jmax))    # Bonan eq. 11.21

    # Ci calculation
    # Medlyn or Ball-Berry:
    if leaf.dynamic_state # Save actual gs
        gs_actual = leaf.gs
    end

    if (leaf.gstyp <= 1)
        Ci_0 = leaf.C3 ? 0.7*flux.cair : 0.4*flux.cair
        # Solve iterative loop:
        leaf.Ci = hybrid(flux,leaf, CiFunc!, Ci_0, 0.7*Ci_0, tol)
    elseif leaf.gstyp == 2 # Needed for Bonan Stomatal optimization model
        leaf.Ci = CiFuncGs!(leaf.gs, flux,leaf)
    end
    if leaf.dynamic_state
        leaf.gs_ss = leaf.gs
        leaf.gs = gs_actual
        leaf.Ci = CiFuncGs!(leaf.gs, flux,leaf)
    end

    # Rate of actual CO2 per electron, incl. photorespiration (not using effcon here for now)
    leaf.CO2_per_electron = (leaf.Ci-leaf.Γstar)/(4leaf.Ci+8leaf.Γstar) #* leaf.effcon;

    # Actual effective ETR:
    flux.Ja = max(0,flux.ag / leaf.CO2_per_electron);
    flux.Ja = min(flux.Ja,flux.Je_pot )

    # Effective photochemical yield:
    flux.φ = leaf.maxPSII*flux.Ja/flux.Je_pot;
    #println(flux.Ja, " ", flux.Je_pot)
    flux.φ = min(1/leaf.maxPSII,flux.φ)
    x   = max(0,  1-flux.φ/leaf.maxPSII);       # degree of light saturation: 'x' (van der Tol e.a. 2014)
    Fluorescencemodel!(flux.φ,x,leaf)


end # LeafPhotosynthesis (similar to biochem in SCOPE)

"""
    CiFunc!(Ci::Number, flux::fluxes, leaf::leaf_params)

Compute Assimilation using Ci as input

# Arguments
- `Ci::Number`: Ci.
- `flux::fluxes`: fluxes structure.
- `leaf::leaf_params`: leaf_params structure.
"""
function CiFunc!(Ci::Number, flux::fluxes, leaf::leaf_params)

    if leaf.C3
        # C3: Rubisco-limited photosynthesis; still need to check CO2 mixing ratios vs partial pressures.
        # still need to include ppm2bar (but can be done on leaf structure!)
        flux.ac = leaf.vcmax * max(Ci-leaf.Γstar, 0.0) / (Ci + leaf.kc*(1.0+leaf.o₂/leaf.ko)) # Bonan eq. 11.28
        # C3: RuBP-limited photosynthesis (this is the NADPH requirement stochiometry)
        flux.aj = flux.je * max(Ci-leaf.Γstar, 0.0) / (4.0*Ci + 8.0*leaf.Γstar)               # Bonan eq. 11.29

        # for C3, set ap to Inf
        flux.ap = Inf
    else #C4 Photosynthesis, still to be implemented
        flux.ac = flux.aj = flux.ap = 0.0
    end
    # Net photosynthesis as the minimum or co-limited rate
    if leaf.use_colim
        flux.ai = minimum(quadratic(leaf.C3 ? 0.98 : 0.80, -(flux.ac + flux.aj), flux.ac * flux.aj))
        if leaf.C3
            flux.ag = flux.ai
        else # C4 colimitation with ap
            flux.ag = minimum(quadratic(0.95, -(flux.ai + flux.ap), flux.ai*flux.ap))                 # Bonan Eq 11.33
        end
    else
        flux.ag = min(flux.ac,flux.aj,flux.ap)
    end
    # Prevent photosynthesis from ever being negative
    flux.ag = max(0,flux.ag)
    flux.ai = max(0,flux.ai)
    flux.aj = max(0,flux.aj)
    flux.ap = max(0,flux.ap)

    # Net photosynthesis
    flux.an = flux.ag - leaf.rdleaf

    # CO2 at leaf surface # might need to be changed
    flux.cs = flux.cair - flux.an / flux.gbc

    # Stomatal constraint function (not sure we "need" the quadratic colimitations here, why not just use BB or Medlyn?)
    if (leaf.gstyp == 1) # Ball-Berry
        if flux.an >0.0
            leaf.gs = maximum(quadratic(flux.cs, flux.cs*(flux.gbv - leaf.g0) - leaf.g1*flux.an, -flux.gbv * (flux.cs*leaf.g0 + leaf.g1*flux.an*flux.ceair/leaf.esat)))
            #leaf.g1 * flux.an * flux.ceair/leaf.esat/flux.cs  + leaf.g0;
            # println(leaf.gs)
        else
            leaf.gs = leaf.g0
        end
    elseif (leaf.gstyp == 0) # Medlyn
        if flux.an >0.0
            # Not sure how this all works, copied from Bonan's ML canopy model
            vpd_term = max((leaf.esat - flux.ceair), vpd_min) * 0.001
            term = 1.6 * flux.an / flux.cs
            leaf.gs = maximum(quadratic(1.0, -(2.0 * (leaf.g0 + term) + (leaf.g1 * term)^2 / (flux.gbv * vpd_term)), leaf.g0 * leaf.g0 + (2.0 * leaf.g0 + term * (1.0 - leaf.g1 * leaf.g1 / vpd_term)) * term))
        else
            leaf.gs = leaf.g0
        end
    end
    # Diffusion (supply-based) photosynthetic rate - Calculate Ci from the diffusion rate
    gleaf = 1.0 / (1.0/flux.gbc + 1.6/leaf.gs + 1.0/leaf.gm)
    cinew = flux.cair - flux.an / gleaf

    # CiFunc returns the difference between the current Ci and the new Ci
    leaf.Ci = cinew
    #return flux.an<0. ? 0.0 : cinew - Ci
    return cinew - Ci
end




"""
    CiFuncGs!(gs::Number, flux::fluxes, leaf::leaf_params)

Compute Assimilation using fixed stomatal conductance gs.

# Arguments
- `gs::Number`: Stomatal conductance.
- `flux::fluxes`: fluxes structure.
- `leaf::leaf_params`: leaf_params structure.
"""
function CiFuncGs!(gs::Number, flux::fluxes, leaf::leaf_params)
    # Compute overall conductance (Boundary layer, stomata and mesophyll)
    gleaf = 1.0/(1.0/flux.gbc + 1.6/gs + 1.0/leaf.gm)
    if gleaf<eps() gleaf=eps() end

    #flux.ac = leaf.vcmax * max(Ci-leaf.Γstar, 0.0) / (Ci + leaf.kc*(1.0+leaf.o₂/leaf.ko)) # Bonan eq. 11.28
    # C3: RuBP-limited photosynthesis (this is the NADPH requirement stochiometry)
    #flux.aj = flux.je * max(Ci-leaf.Γstar, 0.0) / (4.0*Ci + 8.0*leaf.Γstar)               # Bonan eq. 11.29

    if leaf.C3
        # C3 Rubisco Limited Photosynthesis co-limited by gs
        a0 = leaf.vcmax
        e0 = 1.0
        d0 = leaf.kc*(1.0+leaf.o₂/leaf.ko)
        flux.ac = minimum(quadratic(1.0/gleaf, -(e0*flux.cair + d0) - (a0 - e0*leaf.rdleaf) / gleaf, a0 * (flux.cair - leaf.Γstar) - leaf.rdleaf * (e0*flux.cair + d0)))+leaf.rdleaf

        # C3: RuBP-limited photosynthesis
        a0 = flux.je
        e0 = 4.0
        d0 = 8.0*leaf.Γstar
        flux.aj = minimum(quadratic(e0 / gleaf, -(e0*flux.cair + d0) - (a0 - e0*leaf.rdleaf) / gleaf, a0 * (flux.cair - leaf.Γstar) - leaf.rdleaf * (e0*flux.cair + d0)))+leaf.rdleaf

        # C3: Product-limited photosynthesis
        flux.ap = Inf
    # C4 to be implemented
    elseif !leaf.C3
        flux.ac = flux.aj = flux.ap = 0.0
    end
    if leaf.use_colim
        flux.ai = minimum(quadratic(leaf.C3 ? 0.98 : 0.80, -(flux.ac + flux.aj), flux.ac * flux.aj))   # Bonan Eq 11.33
        # Ap limitation only for C4 here:
        if leaf.C3
            flux.ag = flux.ai
        else # C4 colimitation with ap
            flux.ag = minimum(quadratic(0.95, -(flux.ai + flux.ap), flux.ai*flux.ap))                  # Bonan Eq 11.33
        end
    else
        flux.ag = min(flux.ac,flux.aj,flux.ap)
    end
    flux.ag = max(0,flux.ag)
    flux.ai = max(0,flux.ai)
    flux.aj = max(0,flux.aj)
    flux.ap = max(0,flux.ap)
    # Compute net Photosynthesis
    flux.an = flux.ag - leaf.rdleaf
    # Compute CO2 at leaf surface
    flux.cs = flux.cair - flux.an / flux.gbc

    # Compute Ci (included Mesophyll as well in principle)
    ci_val = flux.cair - flux.an / gleaf
    #leaf.CO2_per_electron = (ci_val-leaf.Γstar)./(ci_val+2.0*leaf.Γstar) .* leaf.effcon;
end # Function CiFuncGs!


"""
    Fluorescencemodel!(ps,x,leaf::leaf_params )

Compute Fluorescence yields, Kn and Kp.

# Arguments
- `ps::Number`: PSII yield.
- `x::Number`: Degree of light saturation: [0-1] .
- `leaf::leaf_params`: leaf_params structure.
"""
function Fluorescencemodel!(ps::Number,x::Number,leaf::leaf_params )
    const Kp_max = 4.0
    x_alpha = exp(log(x)*leaf.Knparams[2]); # this is the most expensive operation in this fn; doing it twice almost doubles the time spent here (MATLAB 2013b doesn't optimize the duplicate code)
    #println(x_alpha)
    leaf.Kn_ss = leaf.Knparams[1] * (1+leaf.Knparams[3])* x_alpha/(leaf.Knparams[3] + x_alpha);
    if !leaf.dynamic_state
        leaf.Kn = leaf.Kn_ss
    end
    Kf = leaf.Kf
    Kn = leaf.Kn
    Kd = leaf.Kd
    leaf.Kp   = min(max(0,-ps*(Kf+Kd+Kn)/(ps-1)),Kp_max);
    Kp = leaf.Kp


    leaf.Fo   = Kf/(Kf+Kp_max+Kd);
    leaf.Fo′  = Kf/(Kf+Kp_max+Kd+Kn);
    leaf.Fm   = Kf/(Kf   +Kd);
    leaf.Fm′  = Kf/(Kf   +Kd+Kn);
    leaf.ϕs   = leaf.Fm′*(1-ps);
    leaf.eta  = leaf.ϕs/leaf.Fo;
    leaf.qQ   = 1-(leaf.ϕs-leaf.Fo′)/(leaf.Fm′-leaf.Fo′);
    leaf.qE   = 1-(leaf.Fm-leaf.Fo′)/(leaf.Fm-leaf.Fo);
    leaf.NPQ  = Kn/(Kf+Kd);
end

end #Module
