using FFTW

function fft_m_2d(data, dx, dy, zero_padding_size)

    N = zero_padding_size
    nx, ny = size(data)
    Nx = N > nx ? N : nx
    Ny = N > ny ? N : ny

    new_data = zeros(Nx, Ny)
    for i=1:nx, j=1:ny
        new_data[i,j] = data[i,j]
    end

    fft_m = fftshift(fft(new_data))

    idx = floor(Int,nx/2+1)
    idy = floor(Int,ny/2+1)

    kx = fftshift(fftfreq(Nx, d=dx)*2*pi)
    ky = fftshift(fftfreq(Ny, d=dy)*2*pi)

    Intensity = (abs.(fft_m)).^2

    return kx, ky, Intensity
end

function fft_m_2d_direct(data, dx, dy, kxs, kys)

    nx, ny = size(data)
    fft_m = zeros(Complex{Float64}, length(kxs), length(kys))
    for I in 1:length(kxs), J in 1:length(kys)
        kx, ky = kxs[I], kys[J]
        for i = 1:nx, j=1:ny
            fft_m[I,J] += data[i,j]*exp(-1im*(kx*i*dx+ky*j*dy))
        end
    end
    return (abs.(fft_m)).^2
end

function fft_m(ovf_name, kxs, kys; axis='z')

    ovf = read_ovf(ovf_name)
    nx = ovf.xnodes
    ny = ovf.ynodes
    nz = ovf.znodes
    dx = ovf.xstepsize
    dy = ovf.ystepsize
    dz = ovf.zstepsize
    nxyz = nx*ny*nz
    spin = ovf.data

    m = reshape(spin,(3, nx, ny, nz))
    c = Int(axis) - Int('x') + 1

    Intensity = zeros(length(kxs),length(kys))
    if c == 3
        for k = 1:nz
            I = fft_m_2d_direct(m[3,:,:,k], dx, dy, kxs, kys)
            Intensity .+= I
        end
        return Intensity./nz
    elseif c == 2
        println("will be added later!")
        return nothing
    elseif c == 1
        for i = 1:nx
            I = fft_m_2d_direct(m[1,i,:,:], dy, dz, kxs, kys)
            Intensity .+= I
        end
        return Intensity./nx
    end

    return fft_m(spin, nx, ny, nz, dx, dy, dz, axis)
end


function fft_m(spin, nx, ny, nz, dx, dy, dz, axis, zero_padding_size=-1)
    if !(axis in ['z', 'x', 'y'])
        error("axis should be one of 'x', 'y' and 'z'!!!")
    end

    m = reshape(spin,(3, nx, ny, nz))
    c = Int(axis) - Int('x') + 1

    idx = floor(Int,nx/2+1)
    idy = floor(Int,ny/2+1)
    idz = floor(Int,nz/2+1)

    N = zero_padding_size
    Nx = N > nx ? N : nx
    Ny = N > ny ? N : ny
    Nz = N > nz ? N : nz

    kx = fftshift(fftfreq(Nx, d=dx)*2*pi)
    ky = fftshift(fftfreq(Ny, d=dy)*2*pi)
    kz = fftshift(fftfreq(Nz, d=dz)*2*pi)


    if c == 3
        Intensity = zeros(Nx, Ny)
        for k = 1:nz
            kx, ky, I = fft_m_2d(m[3,:,:,k], dx, dy, zero_padding_size)
            Intensity .+= I
        end
        return kx, ky, Intensity./nz
    elseif c == 2
        println("will be added later!")
        return nothing
    elseif c == 1
        Intensity = zeros(Ny, Nz)
        for i = 1:nx
            ky, kz, I = fft_m_2d(m[1,i,:,:], dy, dz, zero_padding_size)
            Intensity .+= I
        end
        #Intensity[idy,idz] = 0
        return ky, kz, Intensity./nx
    end

    return nothing
end

function fft_m(ovf_name; axis='z', zero_padding_size=-1)

    ovf = read_ovf(ovf_name)
    nx = ovf.xnodes
    ny = ovf.ynodes
    nz = ovf.znodes
    dx = ovf.xstepsize
    dy = ovf.ystepsize
    dz = ovf.zstepsize
    nxyz = nx*ny*nz
    spin = ovf.data

    return fft_m(spin, nx, ny, nz, dx, dy, dz, axis, zero_padding_size)
end


function compute_electric_phase(V, V0, dz, nz)
    C = 299792458.0
    E0 = m_e*C^2
    Ek = V*c_e
    P =  sqrt(Ek^2+2*Ek*E0)/C
    lambda = 2*pi*h_bar/P #lambda in m
    CE = (2*pi/(lambda*V))*(Ek+E0)/(Ek+2*E0)
    phi_E = CE*V0*(dz*nz)
    return lambda, phi_E
end


#df in um
#V is the Accelerating voltage, in Kv
#V0 is the mean inner potential (MIP)
#alpha: beam divergence angle
# use 'axis="x"' to change the axis of LTEM, angle_x = $angle to simulate the titled surface
function LTEM(ovf_name; V=300, Ms=1e5, V0=-26, df=1600, alpha=1e-5, zero_padding_size=512,axis="z",angle_x=0,angle_y=0)
    ovf = read_ovf(ovf_name)
    nx = ovf.xnodes
    ny = ovf.ynodes
    nz = ovf.znodes
    dx = ovf.xstepsize
    dy = ovf.ystepsize
    dz = ovf.zstepsize
    nxyz = nx*ny*nz
    spin = ovf.data
    m = reshape(spin,(3, nx, ny, nz))

    lambda, phi_E = compute_electric_phase(1000*V, V0, dz, nz)
    #println("lambda= ", lambda)
    mx,my,mz = m_average(ovf,axis=axis)
    mx1 = mx
    my1 = my.*cos(angle_y/180*pi) - mz.*sin(angle_y/180*pi)
    mz1 = mz.*cos(angle_y/180*pi) + my.*sin(angle_y/180*pi)  ##after rotation by x-axis

    mx2 = mx1.*cos(angle_x/180*pi)- mz1.*sin(angle_x/180*pi)   ##after rotation by y-axis
    my2 = my1
    mz2 = mz1.*cos(angle_x/180*pi) + mx1.*sin(angle_x/180*pi)

    mx,my,mz = mx2,my2,mz2
    if axis == "x"
        nx =ny
        ny=nz
    elseif axis == "y"
        ny=nz
    end

    N = zero_padding_size
    Nx = N > nx ? N : nx
    Ny = N > ny ? N : ny

    new_mx = zeros(Nx, Ny)
    new_my = zeros(Nx, Ny)
    for i=1:nx, j=1:ny
        new_mx[Int(floor(Nx/2-nx/2+i)),Int(floor(Ny/2-ny/2+j))] = mx[i,j]
        new_my[Int(floor(Nx/2-nx/2+i)),Int(floor(Ny/2-ny/2+j))] = my[i,j]
    end

    fft_mx = fft(new_mx)
    fft_my = fft(new_my)

    kx = fftfreq(Nx, d=dx)*2*pi
    ky = fftfreq(Ny, d=dy)*2*pi

    fft_mx_ky = zeros(Complex{Float64}, (Nx,Ny))
    fft_my_kx = zeros(Complex{Float64}, (Nx,Ny))
    for i=1:Nx, j=1:Ny
        fft_mx_ky[i,j] = fft_mx[i,j]*ky[j]
        fft_my_kx[i,j] = fft_my[i,j]*kx[i]
    end

    Phi_M = zeros(Complex{Float64}, (Nx,Ny))
    T = zeros(Complex{Float64}, (Nx,Ny))
    E = zeros(Nx,Ny)
    df = df*1e-6

    for i=1:Nx, j=1:Ny
        k2 = kx[i]^2 + ky[j]^2
        k = sqrt(k2)
        T[i,j] = exp(pi*1im*(df*lambda*k2))
        E[i,j] = exp(-(pi*alpha*df*k)^2)
        if k2 > 0
            Phi_M[i,j] = 1im*(c_e/h_bar)*pi*mu_0*Ms*(nz*dz)*(fft_mx_ky[i,j]-fft_my_kx[i,j])/k2
        end
    end

    phi_M = abs.(ifft(Phi_M))
    phi = mod.(phi_M .+ phi_E, 2*pi)

    fg = fft(exp.(1im.*phi))
    intensity = (abs.(ifft(fg.*E.*T))).^2;

    local_phi = zeros(nx,ny)
    local_intensity = zeros(nx,ny)

    for i =1:nx,j=1:ny
        local_phi[i,j] = phi_M[Int(floor(Nx/2-nx/2+i)),Int(floor(Ny/2-ny/2+j))]
        local_intensity[i,j] = intensity[Int(floor(Nx/2-nx/2+i)),Int(floor(Ny/2-ny/2+j))]
    end
    #return phi_M, intensity
    return local_phi, local_intensity
end

function m_average(m::Array{T,1},nx::Int,ny::Int,nz::Int;axis::String="z") where T<:AbstractFloat ##axis can only chosen from "x" "y" "z"

    if length(m) != 3*nx*ny*nz
        println("Length doesn't match!")
        return nothing
    end

    b = reshape(m,(3,nx,ny,nz))
    if axis =="x"
        mx,my,mz = zeros(ny,nz),zeros(ny,nz),zeros(ny,nz)
        for i = 1:nx
            mx .+= b[2,i,:,:]/nx
            my .+= b[3,i,:,:]/nx
            mz .+= b[1,i,:,:]/nx
        end
    elseif axis == "y"
        mx,my,mz = zeros(nx,nz),zeros(nx,nz),zeros(nx,nz)
        for j = 1:ny
            mx .-= b[1,:,j,:]/ny
            my .+= b[3,:,j,:]/ny
            mz .+= b[2,:,j,:]/ny
        end
    elseif axis == "z"
        mx,my,mz = zeros(nx,ny),zeros(nx,ny),zeros(nx,ny)
        for k = 1:nz
            mx .+= b[1,:,:,k]/nz
            my .+= b[2,:,:,k]/nz
            mz .+= b[3,:,:,k]/nz
        end
    end

    return mx,my,mz
end

function m_average(ovf::OVF2;axis::String="z")
    m = ovf.data
    nx = ovf.xnodes
    ny = ovf.ynodes
    nz = ovf.znodes

    return m_average(m,nx,ny,nz,axis=axis)
end
