using Random

mutable struct ExchangeMC{TF<:AbstractFloat}
    J::CuArray{TF, 1} #nearest exchange constant
    J1::CuArray{TF, 1} #next-nearest exchange constant
end

mutable struct ZeemanMC{TF<:AbstractFloat}
    Hx::TF
    Hy::TF
    Hz::TF
end

mutable struct DMI_MC{TF<:AbstractFloat}
    D::CuArray{TF, 2} #nearest DMI vector
    D1::CuArray{TF, 2} #next-nearest DMI vector
end

mutable struct Anisotropy_MC{TF<:AbstractFloat}
    Ku::TF
    ux::TF
    uy::TF
    uz::TF
    Kc::TF
end

mutable struct MonteCarloNew{TF<:AbstractFloat} <:AbstractSimGPU
  mesh::Mesh
  mu_s::Float64
  exch::ExchangeMC
  dmi::DMI_MC
  zee::ZeemanMC
  anis::Anisotropy_MC
  saver::DataSaver
  spin::CuArray{TF, 1}
  nextspin::CuArray{TF, 1}
  rnd::CuArray{TF, 1}
  energy::CuArray{TF, 1}
  delta_E::CuArray{TF, 1}
  total_energy::TF
  nxyz::Int64
  steps::Int64
  name::String
  T::Float64
  MonteCarloNew{T}() where {T<:AbstractFloat} = new()
end

function MonteCarloNew(mesh::Mesh; name="mc")
    Float = _cuda_using_double.x ? Float64 : Float32
    sim = MonteCarloNew{Float}()
    sim.mesh = mesh
    nxyz = mesh.nx*mesh.ny*mesh.nz
    sim.nxyz = nxyz

    sim.spin = CuArrays.zeros(Float, 3*nxyz)
    sim.nextspin = CuArrays.zeros(Float,3*nxyz)
    sim.rnd = CuArrays.zeros(Float,3*nxyz)
    sim.energy = CuArrays.zeros(Float,nxyz)
    sim.delta_E = CuArrays.zeros(Float,nxyz)
    sim.steps = 0
    sim.name = name
    sim.T = 300
    sim.mu_s = 1.0*mu_B
    sim.exch = ExchangeMC(CuArrays.zeros(Float, mesh.n_ngbs), CuArrays.zeros(Float, mesh.n_ngbs))
    sim.dmi = DMI_MC(CuArrays.zeros(Float, (3, mesh.n_ngbs)), CuArrays.zeros(Float, (3, mesh.n_ngbs)))
    sim.zee = ZeemanMC(0.0,0.0,0.0)
    sim.anis = Anisotropy_MC(Float(0),Float(0),Float(0),Float(1),Float(0))

    headers = ["step", "time", "E_total", ("m_x", "m_y", "m_z")]
    units = ["<>", "<s>", "<J>",("<>", "<>", "<>")]
    results = [o::AbstractSim -> o.saver.nsteps,
             o::AbstractSim -> o.saver.t,
             o::AbstractSim -> o.total_energy, average_m]
    saver = DataSaver(string(name, ".txt"), 0.0, 0, false, headers, units, results)
    sim.saver = saver

    return sim
end

function add_exch(sim::MonteCarloNew, Jx, Jy, Jz, Jx1, Jy1, Jz1)
    cubic = isa(sim.mesh, CubicMeshGPU) ? true : false
    if !cubic
        error("This function only works for CubicMeshGPU!")
    end
    exch = sim.exch
    T = _cuda_using_double.x ? Float64 : Float32
    Jx = Jx/k_B
    Jy = Jy/k_B
    Jz = Jz/k_B
    Jx1 = Jx1/k_B
    Jx2 = Jx2/k_B
    Jx3 = Jx3/k_B
    J = Array([T(Jx/k_B), T(Jx), T(Jy), T(Jy), T(Jz), T(Jz)])
    J1 = Array([T(Jx1), T(Jx1), T(Jy1), T(Jy1), T(Jz1), T(Jz1)])
    copyto!(exch.J, J)
    copyto!(exch.J1, J1)
    return nothing
end

function add_exch(sim::MonteCarloNew; J=1, J1=0)
    sim.exch.J .= J/k_B
    sim.exch.J1 .= J1/k_B
    return nothing
end

function add_dmi(sim::MonteCarloNew, Dx::Float64, Dy::Float64, Dz::Float64, Dx1::Float64, Dy1::Float64, Dz1::Float64, type::String)
    dmi = sim.dmi
    cubic = isa(sim.mesh, CubicMeshGPU) ? true : false
    if !cubic
        error("This function only works for CubicMeshGPU!")
    end
    T = _cuda_using_double.x ? Float64 : Float32
    Dx = Dx/k_B
    Dy = Dy/k_B
    Dz = Dz/k_B
    Dx1 = Dx1/k_B
    Dy1 = Dy1/k_B
    Dz1 = Dz1/k_B
    D = zeros(T, (3, 6))
    D1 = zeros(T, (3, 6))

    if type == "bulk"
        D[1, 1] = -Dx
        D[1, 2] = Dx
        D[2, 3] = -Dy
        D[2, 4] = Dy
        D[3, 5] = -Dz
        D[3, 6] = Dz

        D1[1, 1] = -Dx1
        D1[1, 2] = Dx1
        D1[2, 3] = -Dy1
        D1[2, 4] = Dy1
        D1[3, 5] = -Dz1
        D1[3, 6] = Dz1
    elseif type == "interfacial"
        D[1, 3] = -Dy
        D[1, 4] = Dy
        D[2, 1] = Dx
        D[2, 2] = -Dx

        D1[1, 3] = -Dy1
        D1[1, 4] = Dy1
        D1[2, 1] = Dx1
        D1[2, 2] = -Dx1
    end

    copyto!(dmi.D, D)
    copyto!(dmi.D1, D1)
    return nothing
end

function add_dmi(sim::MonteCarloNew; D=1.0, D1=0.0, type="bulk")
    D = Float64(D)
    D1 = Float64(D1)
    add_dmi(sim, D, D, D, D1, D1, D1, type)
    return nothing
end

function add_zeeman(sim::MonteCarloNew; Hx=0, Hy=0, Hz=0)
    zeeman = sim.zee
    zeeman.Hx = Hx*sim.mu_s
    zeeman.Hy = Hy*sim.mu_s
    zeeman.Hz = Hz*sim.mu_s
    return nothing
end

function add_anis(sim::MonteCarloNew; Ku=1, Kc=0, axis=(0,0,1))
    anis = sim.anis
    anis.Ku = Ku/k_B
    length = sqrt(axis[1]^2+axis[2]^2+axis[3]^2)
    if length < 1e-15
        anis.uz  = 1.0
    else
        anis.ux = axis[1]/length
        anis.uy = axis[2]/length
        anis.uz = axis[3]/length
    end
    anis.Kc = Kc/k_B
    return nothing
end


function init_m0(sim::MonteCarloNew, m0::Any; norm=true)
  Float = _cuda_using_double.x ? Float64 : Float32
  spin = zeros(Float, 3*sim.nxyz)
  init_vector!(spin, sim.mesh, m0)
  if norm
    normalise(spin, sim.nxyz)
  end
  copyto!(sim.spin, spin)
  return true
end


function run_step(sim::MonteCarloNew)

  uniform_random_sphere(sim.nextspin, sim.rnd, sim.nxyz)
  run_single_step(sim, 0)
  run_single_step(sim, 1)
  run_single_step(sim, 2)
  sim.steps += 1

  return  nothing
end

function run_single_step(sim::MonteCarloNew, bias::Int64)
    blk, thr = CuArrays.cudims(sim.nxyz)
    zee = sim.zee
    anis = sim.anis
    exch = sim.exch
    dmi = sim.dmi
    mesh = sim.mesh
    @cuda blocks=blk threads=thr dE_zeeman_anisotropy_kernel!(sim.spin, sim.nextspin,
                                    sim.energy, mesh.ngbs, mesh.nngbs,
                                    zee.Hx, zee.Hy, zee.Hz,
                                    anis.Ku, anis.Kc, anis.ux, anis.uy, anis.uz,
                                    mesh.nx, mesh.ny, mesh.nz, bias)

    @cuda blocks=blk threads=thr add_dE_exch_dmi_kernel!(sim.spin, sim.nextspin,
                                    sim.energy, mesh.ngbs, mesh.nngbs,
                                    mesh.n_ngbs,
                                    exch.J, exch.J1, dmi.D, dmi.D1,
                                    mesh.nx, mesh.ny, mesh.nz, bias)

    @cuda blocks=blk threads=thr  run_monte_carlo_kernel!(sim.spin, sim.nextspin, sim.rnd,
                                    sim.energy, sim.T,
                                    mesh.nx, mesh.ny, mesh.nz, bias)

  return nothing
end


function compute_system_energy(sim::MonteCarloNew)
    F = _cuda_using_double.x ? Float64 : Float32
    mesh = sim.mesh
    zee = sim.zee
    anis = sim.anis
    exch = sim.exch
    dmi = sim.dmi
    blk, thr = CuArrays.cudims(sim.nxyz)
    @cuda blocks=blk threads=thr total_energy_kernel!(sim.spin,
                                 sim.energy,
                                 mesh.ngbs, mesh.nngbs, mesh.n_ngbs,
                                 zee.Hx, zee.Hy, zee.Hz,
                                 anis.Ku, anis.Kc, anis.ux, anis.uy, anis.uz,
                                 exch.J, exch.J1, dmi.D, dmi.D1,
                                 mesh.nxyz)
    return sum(sim.energy)*k_B
end


function run_sim(sim::MonteCarloNew; maxsteps=10000, save_m_every = 10, save_vtk_every=-1, save_ovf_every=-1, ovf_format="binary8")
    cubic = isa(sim.mesh, CubicMeshGPU) ? true : false
    for i=1:maxsteps

        if save_m_every>0
            if sim.steps%save_m_every == 0
                energy = compute_system_energy(sim)
                @info @sprintf("step=%5d  total_energy=%g", sim.steps, energy)
            end
        end

        if save_ovf_every > 0
            if sim.steps%save_ovf_every == 0
                save_ovf(sim, @sprintf("%s_%d", sim.name, sim.steps), dataformat = ovf_format)
            end
        end

        if save_vtk_every > 0
            if sim.steps%save_vtk_every == 0
              save_vtk(sim, @sprintf("%s_%d", sim.name, sim.steps))
            end
        end

        if cubic
           run_step(sim)
        else
           run_step_triangular(sim)
        end

    end
end
