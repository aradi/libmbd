! This Source Code Form is subject to the terms of the Mozilla Public
! License, v. 2.0. If a copy of the MPL was not distributed with this
! file, You can obtain one at http://mozilla.org/MPL/2.0/.
module mbd

use mbd_interface, only: &
    sync_sum, broadcast, print_error, print_warning, print_log, pi
use mbd_common, only: tostr, nan, print_matrix
use mbd_linalg, only: &
    operator(.cprod.), diag, invert, diagonalize, sdiagonalize, diagonalized, &
    sdiagonalized, inverted, sinvert

implicit none

private
public :: mbd_param, mbd_calc, mbd_damping, mbd_work, mbd_system, mbd_relay, &
    init_grid, get_mbd_energy, dipole_matrix, mbd_rsscs_energy, mbd_scs_energy, &
    run_tests, get_sigma_selfint
public :: get_ts_energy, init_eqi_grid, eval_mbd_nonint_density, &
    eval_mbd_int_density, nbody_coeffs, get_damping_parameters, v_to_r, &
    clock_rate

real(8), parameter :: ang = 1.8897259886d0
integer, parameter :: n_timestamps = 100

type mbd_param
    real(8) :: ts_energy_accuracy = 1.d-10
    real(8) :: ts_cutoff_radius = 50.d0*ang
    real(8) :: dipole_low_dim_cutoff = 100.d0*ang
    real(8) :: dipole_cutoff = 400.d0*ang  ! used only when Ewald is off
    real(8) :: mayer_scaling = 1.d0
    real(8) :: ewald_real_cutoff_scaling = 1.d0
    real(8) :: ewald_rec_cutoff_scaling = 1.d0
    real(8) :: k_grid_shift = 0.5d0
    logical :: ewald_on = .true.
    logical :: zero_negative_eigs = .false.
    logical :: vacuum_axis(3) = (/ .false., .false., .false. /)
    integer :: mbd_nbody_max = 3
    integer :: rpa_order_max = 10
    integer :: n_frequency_grid = 15
end type

type mbd_timing
    logical :: measure_time = .true.
    integer :: timestamps(n_timestamps), ts_counts(n_timestamps)
    integer :: ts_cnt, ts_rate, ts_cnt_max, ts_aid
end type mbd_timing

type mbd_calc
    type(mbd_param) :: param
    type(mbd_timing) :: tm
    integer :: n_freq
    real(8), allocatable :: omega_grid(:)
    real(8), allocatable :: omega_grid_w(:)
    logical :: parallel = .false.
    integer :: my_task = 0
    integer :: n_tasks = 1
    logical :: mute = .false.
end type mbd_calc

type mbd_damping
    character(len=20) :: version
    real(8) :: beta = 0.d0
    real(8) :: a = 6.d0
    real(8), allocatable :: r_vdw(:)
    real(8), allocatable :: sigma(:)
    real(8), allocatable :: damping_custom(:, :)
    real(8), allocatable :: potential_custom(:, :, :, :)
end type mbd_damping

type mbd_work
    logical :: get_eigs = .false.
    logical :: get_modes = .false.
    logical :: get_rpa_orders = .false.
    integer :: i_kpt = 0
    real(8), allocatable :: k_pts(:, :)
    real(8), allocatable :: mode_enes(:)
    real(8), allocatable :: modes(:, :)
    real(8), allocatable :: rpa_orders(:)
    real(8), allocatable :: mode_enes_k(:, :)
    complex(8), allocatable :: modes_k(:, :, :)
    real(8), allocatable :: rpa_orders_k(:, :)
end type

type mbd_system
    type(mbd_calc), pointer :: calc
    type(mbd_work) :: work
    real(8), allocatable :: coords(:, :)
    logical :: periodic = .false.
    real(8) :: lattice(3, 3)
    integer :: k_grid(3)
    integer :: supercell(3)
    logical :: do_rpa = .false.
    logical :: do_reciprocal = .true.
    logical :: do_force = .false.
end type mbd_system

type mbd_relay
    real(8), allocatable :: re(:, :)
    complex(8), allocatable :: cplx(:, :)
    real(8), allocatable :: re_dr(:, :, :)
end type mbd_relay

! the following types are internal and serve for simultaneous passing of
! quantities and their force derivatives between functions

type dip33
    real(8) :: val(3, 3)
    ! explicit derivative, [abc] ~ dval_{ab}/dR_c
    real(8) :: dr(3, 3, 3)
    logical :: has_vdw = .false.
    real(8) :: dvdw(3, 3)
    logical :: has_sigma = .false.
    real(8) :: dsigma(3, 3)
end type

type scalar
    real(8) :: val
    real(8) :: dr(3)  ! explicit derivative
    real(8) :: dvdw
end type

contains


real(8) function mbd_rsscs_energy(sys, alpha_0, omega, damp)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    type(mbd_damping), intent(in) :: damp

    real(8), allocatable :: alpha_dyn(:, :)
    real(8), allocatable :: alpha_dyn_rsscs(:, :)
    real(8), allocatable :: C6_rsscs(:)
    real(8), allocatable :: R_vdw_rsscs(:)
    real(8), allocatable :: omega_rsscs(:)
    type(mbd_damping) :: damp_rsscs, damp_mbd

    allocate (alpha_dyn(0:sys%calc%n_freq, size(sys%coords, 1)))
    allocate (alpha_dyn_rsscs(0:sys%calc%n_freq, size(sys%coords, 1)))
    alpha_dyn = alpha_dynamic_ts(sys%calc, alpha_0, omega)
    damp_rsscs = damp
    damp_rsscs%version = 'fermi,dip,gg'
    alpha_dyn_rsscs = run_scs(sys, alpha_dyn, damp_rsscs)
    C6_rsscs = get_C6_from_alpha(sys%calc, alpha_dyn_rsscs)
    R_vdw_rsscs = damp%R_vdw*(alpha_dyn_rsscs(0, :)/alpha_dyn(0, :))**(1.d0/3)
    damp_mbd%version = 'fermi,dip'
    damp_mbd%r_vdw = R_vdw_rsscs
    damp_mbd%beta = damp%beta
    omega_rsscs = omega_eff(C6_rsscs, alpha_dyn_rsscs(0, :))
    mbd_rsscs_energy = get_mbd_energy(sys, alpha_dyn_rsscs(0, :), omega_rsscs, damp_mbd)
end function mbd_rsscs_energy


real(8) function mbd_scs_energy(sys, alpha_0, omega, damp)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    type(mbd_damping), intent(in) :: damp

    real(8), allocatable :: alpha_dyn(:, :)
    real(8), allocatable :: alpha_dyn_scs(:, :)
    real(8), allocatable :: C6_scs(:)
    real(8), allocatable :: R_vdw_scs(:)
    real(8), allocatable :: omega_scs(:)
    type(mbd_damping) :: damp_scs, damp_mbd

    allocate (alpha_dyn(0:sys%calc%n_freq, size(sys%coords, 1)))
    allocate (alpha_dyn_scs(0:sys%calc%n_freq, size(sys%coords, 1)))
    alpha_dyn = alpha_dynamic_ts(sys%calc, alpha_0, omega)
    damp_scs = damp
    damp_scs%version = 'dip,gg'
    alpha_dyn_scs = run_scs(sys, alpha_dyn, damp_scs)
    C6_scs = get_C6_from_alpha(sys%calc, alpha_dyn_scs)
    R_vdw_scs = damp%R_vdw*(alpha_dyn_scs(0, :)/alpha_dyn(0, :))**(1.d0/3)
    damp_mbd%version = 'dip,1mexp'
    damp_mbd%r_vdw = R_vdw_scs
    damp_mbd%beta = 1.d0
    damp_mbd%a = damp%a
    omega_scs = omega_eff(C6_scs, alpha_dyn_scs(0, :))
    mbd_scs_energy = get_mbd_energy(sys, alpha_dyn_scs(0, :), omega_scs, damp_mbd)
end function mbd_scs_energy


function get_ts_energy(calc, mode, version, xyz, C6, alpha_0, R_vdw, s_R, &
        d, overlap, damping_custom, unit_cell) result(ene)
    type(mbd_calc), intent(in) :: calc
    character(len=*), intent(in) :: mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        C6(size(xyz, 1)), &
        alpha_0(size(xyz, 1))
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        s_R, &
        d, &
        overlap(size(xyz, 1), size(xyz, 1)), &
        damping_custom(size(xyz, 1), size(xyz, 1)), &
        unit_cell(3, 3)
    real(8) :: ene

    real(8) :: C6_ij, r(3), r_norm, R_vdw_ij, overlap_ij, &
        ene_shell, ene_pair, R_cell(3)
    type(scalar) :: f_damp
    integer :: i_shell, i_cell, i_atom, j_atom, range_cell(3), idx_cell(3)
    real(8), parameter :: shell_thickness = 10.d0
    logical :: is_crystal, is_parallel

    is_crystal = is_in('C', mode)
    is_parallel = is_in('P', mode)

    ene = 0.d0
    i_shell = 0
    do
        i_shell = i_shell+1
        ene_shell = 0.d0
        if (is_crystal) then
            range_cell = supercell_circum(calc, unit_cell, i_shell*shell_thickness)
        else
            range_cell = (/ 0, 0, 0 /)
        end if
        idx_cell = (/ 0, 0, -1 /)
        do i_cell = 1, product(1+2*range_cell)
            call shift_cell(idx_cell, -range_cell, range_cell)
            ! MPI code begin
            if (is_parallel .and. is_crystal) then
                if (calc%my_task /= modulo(i_cell, calc%n_tasks)) cycle
            end if
            ! MPI code end
            if (is_crystal) then
                R_cell = matmul(idx_cell, unit_cell)
            else
                R_cell = (/ 0.d0, 0.d0, 0.d0 /)
            end if
            do i_atom = 1, size(xyz, 1)
                ! MPI code begin
                if (is_parallel .and. .not. is_crystal) then
                    if (calc%my_task /= modulo(i_atom, calc%n_tasks)) cycle
                end if
                ! MPI code end
                do j_atom = 1, i_atom
                    if (i_cell == 1) then
                        if (i_atom == j_atom) cycle
                    end if
                    r = xyz(i_atom, :)-xyz(j_atom, :)-R_cell
                    r_norm = sqrt(sum(r**2))
                    if (r_norm > calc%param%ts_cutoff_radius) cycle
                    if (r_norm >= i_shell*shell_thickness &
                        .or. r_norm < (i_shell-1)*shell_thickness) then
                        cycle
                    end if
                    C6_ij = combine_C6( &
                        C6(i_atom), C6(j_atom), &
                        alpha_0(i_atom), alpha_0(j_atom))
                    if (present(R_vdw)) then
                        R_vdw_ij = R_vdw(i_atom)+R_vdw(j_atom)
                    end if
                    if (present(overlap)) then
                        overlap_ij = overlap(i_atom, j_atom)
                    end if
                    select case (version)
                        case ("fermi")
                            f_damp = damping_fermi(r, s_R*R_vdw_ij, d, .false.)
                        case ("fermi2")
                            f_damp = damping_fermi(r, s_R*R_vdw_ij, d, .false.)
                            f_damp%val = f_damp%val**2
                        case ("custom")
                            f_damp%val = damping_custom(i_atom, j_atom)
                    end select
                    ene_pair = -C6_ij*f_damp%val/r_norm**6
                    if (i_atom == j_atom) then
                        ene_shell = ene_shell+ene_pair/2
                    else
                        ene_shell = ene_shell+ene_pair
                    endif
                end do ! j_atom
            end do ! i_atom
        end do ! i_cell
        ! MPI code begin
        if (is_parallel) then
            call sync_sum(ene_shell)
        end if
        ! MPI code end
        ene = ene+ene_shell
        if (.not. is_crystal) exit
        if (i_shell > 1 .and. abs(ene_shell) < calc%param%ts_energy_accuracy) then
            call print_log("Periodic TS converged in " &
                //trim(tostr(i_shell))//" shells, " &
                //trim(tostr(i_shell*shell_thickness/ang))//" angstroms")
            exit
        endif
    end do ! i_shell

    contains

    function is_in(c, str) result(is)
        character(len=1), intent(in) :: c
        character(len=*), intent(in) :: str
        logical :: is

        integer :: i

        is = .false.
        do i = 1, len(str)
            if (c == str(i:i)) then
                is = .true.
                exit
            end if
        end do
    end function is_in
end function get_ts_energy


type(mbd_relay) function dipole_matrix(sys, damp, k_point) result(dipmat)
    type(mbd_system), intent(inout) :: sys
    type(mbd_damping), intent(in) :: damp
    real(8), intent(in), optional :: k_point(3)

    real(8) :: R_cell(3), r(3), r_norm, R_vdw_ij, &
        sigma_ij, volume, ewald_alpha, real_space_cutoff, f_ij
    type(dip33) :: Tpp
    complex(8) :: Tpp_c(3, 3)
    character(len=1) :: parallel_mode
    integer :: i_atom, j_atom, i_cell, idx_cell(3), range_cell(3), i, j, n_atoms
    logical :: mute, do_ewald

    do_ewald = .false.
    mute = sys%calc%mute
    n_atoms = size(sys%coords, 1)
    if (sys%calc%parallel) then
        parallel_mode = 'A' ! atoms
        if (sys%periodic .and. n_atoms < sys%calc%n_tasks) then
            parallel_mode = 'C' ! cells
        end if
    else
        parallel_mode = ''
    end if

    if (present(k_point)) then
        allocate (dipmat%cplx(3*n_atoms, 3*n_atoms), source=(0.d0, 0.d0))
    else
        allocate (dipmat%re(3*n_atoms, 3*n_atoms), source=0.d0)
        if (sys%do_force) then
            allocate (dipmat%re_dr(3*n_atoms, 3*n_atoms, 3), source=0.d0)
        end if
    end if
    ! MPI code end
    if (sys%periodic) then
        if (any(sys%calc%param%vacuum_axis)) then
            real_space_cutoff = sys%calc%param%dipole_low_dim_cutoff
        else if (sys%calc%param%ewald_on) then
            do_ewald = .true.
            volume = max(abs(dble(product(diagonalized(sys%lattice)))), 0.2d0)
            ewald_alpha = 2.5d0/(volume)**(1.d0/3)
            real_space_cutoff = 6.d0/ewald_alpha*sys%calc%param%ewald_real_cutoff_scaling
            call print_log('Ewald: using alpha = '//trim(tostr(ewald_alpha)) &
                //', real cutoff = '//trim(tostr(real_space_cutoff)), mute)
        else
            real_space_cutoff = sys%calc%param%dipole_cutoff
        end if
        range_cell = supercell_circum(sys%calc, sys%lattice, real_space_cutoff)
    else
        range_cell(:) = 0
    end if
    if (sys%periodic) then
        call print_log('Ewald: summing real part in cell vector range of ' &
            //trim(tostr(1+2*range_cell(1)))//'x' &
            //trim(tostr(1+2*range_cell(2)))//'x' &
            //trim(tostr(1+2*range_cell(3))), mute)
    end if
    call ts(sys%calc, 11)
    idx_cell = (/ 0, 0, -1 /)
    do i_cell = 1, product(1+2*range_cell)
        call shift_cell(idx_cell, -range_cell, range_cell)
        ! MPI code begin
        if (parallel_mode == 'C') then
            if (sys%calc%my_task /= modulo(i_cell, sys%calc%n_tasks)) cycle
        end if
        ! MPI code end
        if (sys%periodic) then
            R_cell = matmul(idx_cell, sys%lattice)
        else
            R_cell(:) = 0.d0
        end if
        do i_atom = 1, n_atoms
            ! MPI code begin
            if (parallel_mode == 'A') then
                if (sys%calc%my_task /= modulo(i_atom, sys%calc%n_tasks)) cycle
            end if
            ! MPI code end
            !$omp parallel do private(r, r_norm, R_vdw_ij, sigma_ij, overlap_ij, C6_ij, &
            !$omp    Tpp, i, j, Tpp_c)
            do j_atom = i_atom, n_atoms
                if (i_cell == 1) then
                    if (i_atom == j_atom) cycle
                end if
                r = sys%coords(i_atom, :)-sys%coords(j_atom, :)-R_cell
                r_norm = sqrt(sum(r**2))
                if (sys%periodic .and. r_norm > real_space_cutoff) cycle
                if (allocated(damp%R_vdw)) then
                    R_vdw_ij = damp%R_vdw(i_atom)+damp%R_vdw(j_atom)
                end if
                if (allocated(damp%sigma)) then
                    sigma_ij = sqrt(sum(damp%sigma([i_atom, j_atom])**2))
                end if
                select case (damp%version)
                    case ("bare")
                        Tpp%val = T_bare(r)
                    case ("dip,1mexp")
                        Tpp%val = T_1mexp_coulomb(r, damp%beta*R_vdw_ij, damp%a)
                    case ("fermi,dip")
                        Tpp = T_damped( &
                            sys, &
                            damping_fermi(r, damp%beta*R_vdw_ij, damp%a, sys%do_force), &
                            T_bare_v2(r, sys%do_force), &
                            .false. &
                        )
                    case ("custom,dip")
                        Tpp%val = damp%damping_custom(i_atom, j_atom)*T_bare(r)
                    case ("dip,custom")
                        Tpp%val = damp%potential_custom(i_atom, j_atom, :, :)
                    case ("dip,gg")
                        Tpp = T_erf_coulomb(r, sigma_ij, sys%do_force)
                    case ("fermi,dip,gg")
                        Tpp = T_damped( &
                            sys, &
                            damping_fermi(r, damp%beta*R_vdw_ij, damp%a, sys%do_force), &
                            T_erf_coulomb(r, sigma_ij, sys%do_force), &
                            .true. &
                        )
                        do_ewald = .false.
                    case ("custom,dip,gg")
                        f_ij = 1.d0-damp%damping_custom(i_atom, j_atom)
                        Tpp = T_erf_coulomb(r, sigma_ij, sys%do_force)
                        Tpp%val = f_ij*Tpp%val
                        do_ewald = .false.
                end select
                if (do_ewald) then
                    Tpp%val = Tpp%val+T_erfc(r, ewald_alpha)-T_bare(r)
                end if
                if (present(k_point)) then
                    Tpp_c = Tpp%val*exp(-cmplx(0.d0, 1.d0, 8)*( &
                        dot_product(k_point, r)))
                end if
                i = 3*(i_atom-1)
                j = 3*(j_atom-1)
                if (present(k_point)) then
                    associate (T => dipmat%cplx(i+1:i+3, j+1:j+3))
                        T = T + Tpp_c
                    end associate
                else
                    associate (T => dipmat%re(i+1:i+3, j+1:j+3))
                        T = T + Tpp%val
                    end associate
                    if (sys%do_force) then
                        associate (T => dipmat%re_dr(i+1:i+3, j+1:j+3, :))
                            T = T + Tpp%dr
                        end associate
                    end if
                end if
            end do ! j_atom
            !$omp end parallel do
        end do ! i_atom
    end do ! i_cell
    call ts(sys%calc, -11)
    ! MPI code begin
    if (sys%calc%parallel) then
        if (present(k_point)) then
            call sync_sum(dipmat%cplx)
        else
            call sync_sum(dipmat%re)
        end if
    end if
    ! MPI code end
    if (do_ewald) then
        call add_ewald_dipole_parts(sys, ewald_alpha, dipmat, k_point)
    end if
end function dipole_matrix


subroutine add_ewald_dipole_parts(sys, alpha, dipmat, k_point)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha
    real(8), intent(in), optional :: k_point(3)
    type(mbd_relay), intent(inout) :: dipmat

    logical :: is_parallel, mute, do_surface
    real(8) :: rec_unit_cell(3, 3), volume, G_vector(3), r(3), k_total(3), &
        k_sq, rec_space_cutoff, Tpp(3, 3), k_prefactor(3, 3), elem
    complex(8) :: Tpp_c(3, 3)
    integer :: &
        i_atom, j_atom, i, j, i_xyz, j_xyz, idx_G_vector(3), i_G_vector, &
        range_G_vector(3)
    character(len=1) :: parallel_mode

    is_parallel = sys%calc%parallel
    mute = sys%calc%mute
    if (is_parallel) then
        parallel_mode = 'A' ! atoms
        if (size(sys%coords, 1) < sys%calc%n_tasks) then
            parallel_mode = 'G' ! G vectors
        end if
    else
        parallel_mode = ''
    end if

    ! MPI code begin
    if (is_parallel) then
        ! will be restored by syncing at the end
        if (present(k_point)) then
            dipmat%cplx = dipmat%cplx/sys%calc%n_tasks
        else
            dipmat%re = dipmat%re/sys%calc%n_tasks
        end if
    end if
    ! MPI code end
    rec_unit_cell = 2*pi*inverted(transpose(sys%lattice))
    volume = abs(dble(product(diagonalized(sys%lattice))))
    rec_space_cutoff = 10.d0*alpha*sys%calc%param%ewald_rec_cutoff_scaling
    range_G_vector = supercell_circum(sys%calc, rec_unit_cell, rec_space_cutoff)
    call print_log('Ewald: using reciprocal cutoff = ' &
        //trim(tostr(rec_space_cutoff)), mute)
    call print_log('Ewald: summing reciprocal part in G vector range of ' &
        //trim(tostr(1+2*range_G_vector(1)))//'x' &
        //trim(tostr(1+2*range_G_vector(2)))//'x' &
        //trim(tostr(1+2*range_G_vector(3))), mute)
    call ts(sys%calc, 12)
    idx_G_vector = (/ 0, 0, -1 /)
    do i_G_vector = 1, product(1+2*range_G_vector)
        call shift_cell(idx_G_vector, -range_G_vector, range_G_vector)
        if (i_G_vector == 1) cycle
        ! MPI code begin
        if (parallel_mode == 'G') then
            if (sys%calc%my_task /= modulo(i_G_vector, sys%calc%n_tasks)) cycle
        end if
        ! MPI code end
        G_vector = matmul(idx_G_vector, rec_unit_cell)
        if (present(k_point)) then
            k_total = k_point+G_vector
        else
            k_total = G_vector
        end if
        k_sq = sum(k_total**2)
        if (sqrt(k_sq) > rec_space_cutoff) cycle
        k_prefactor(:, :) = 4*pi/volume*exp(-k_sq/(4*alpha**2))
        forall (i_xyz = 1:3, j_xyz = 1:3) &
                k_prefactor(i_xyz, j_xyz) = k_prefactor(i_xyz, j_xyz) &
                *k_total(i_xyz)*k_total(j_xyz)/k_sq
        do i_atom = 1, size(sys%coords, 1)
            ! MPI code begin
            if (parallel_mode == 'A') then
                if (sys%calc%my_task /= modulo(i_atom, sys%calc%n_tasks)) cycle
            end if
            ! MPI code end
            !$omp parallel do private(r, Tpp, i, j, Tpp_c)
            do j_atom = i_atom, size(sys%coords, 1)
                r = sys%coords(i_atom, :)-sys%coords(j_atom, :)
                if (present(k_point)) then
                    Tpp_c = k_prefactor*exp(cmplx(0.d0, 1.d0, 8) &
                        *dot_product(G_vector, r))
                else
                    Tpp = k_prefactor*cos(dot_product(G_vector, r))
                end if
                i = 3*(i_atom-1)
                j = 3*(j_atom-1)
                if (present(k_point)) then
                    associate (T => dipmat%cplx(i+1:i+3, j+1:j+3))
                        T = T + Tpp_c
                    end associate
                else
                    associate (T => dipmat%re(i+1:i+3, j+1:j+3))
                        T = T + Tpp
                    end associate
                end if
            end do ! j_atom
            !$omp end parallel do
        end do ! i_atom
    end do ! i_G_vector
    ! MPI code begin
    if (is_parallel) then
        if (present(k_point)) then
            call sync_sum(dipmat%cplx)
        else
            call sync_sum(dipmat%re)
        end if
    end if
    ! MPI code end
    do i_atom = 1, size(sys%coords, 1) ! self energy
        do i_xyz = 1, 3
            i = 3*(i_atom-1)+i_xyz
            if (present(k_point)) then
                dipmat%cplx(i, i) = dipmat%cplx(i, i)-4*alpha**3/(3*sqrt(pi))
            else
                dipmat%re(i, i) = dipmat%re(i, i)-4*alpha**3/(3*sqrt(pi))
            end if
        end do
    end do
    do_surface = .true.
    if (present(k_point)) then
        k_sq = sum(k_point**2)
        if (sqrt(k_sq) > 1.d-15) then
            do_surface = .false.
            do i_atom = 1, size(sys%coords, 1)
            do j_atom = i_atom, size(sys%coords, 1)
                do i_xyz = 1, 3
                do j_xyz = 1, 3
                    i = 3*(i_atom-1)+i_xyz
                    j = 3*(j_atom-1)+j_xyz
                    elem = 4*pi/volume*k_point(i_xyz)*k_point(j_xyz)/k_sq &
                        *exp(-k_sq/(4*alpha**2))
                    if (present(k_point)) then
                        dipmat%cplx(i, j) = dipmat%cplx(i, j) + elem
                    else
                        dipmat%re(i, j) = dipmat%re(i, j) + elem
                    end if ! present(k_point)
                end do ! j_xyz
                end do ! i_xyz
            end do ! j_atom
            end do ! i_atom
        end if ! k_sq >
    end if ! k_point present
    if (do_surface) then ! surface energy
        do i_atom = 1, size(sys%coords, 1)
        do j_atom = i_atom, size(sys%coords, 1)
            do i_xyz = 1, 3
                i = 3*(i_atom-1)+i_xyz
                j = 3*(j_atom-1)+i_xyz
                if (present(k_point)) then
                    dipmat%cplx(i, j) = dipmat%cplx(i, j) + 4*pi/(3*volume)
                else
                    dipmat%re(i, j) = dipmat%re(i, j) + 4*pi/(3*volume)
                end if
            end do ! i_xyz
        end do ! j_atom
        end do ! i_atom
    end if
    call ts(sys%calc, -12)
end subroutine


subroutine init_grid(calc)
    type(mbd_calc), intent(inout) :: calc

    integer :: n

    n = calc%param%n_frequency_grid
    allocate (calc%omega_grid(0:n))
    allocate (calc%omega_grid_w(0:n))
    calc%n_freq = n
    calc%omega_grid(0) = 0.d0
    calc%omega_grid_w(0) = 0.d0
    call get_omega_grid(n, 0.6d0, calc%omega_grid(1:n), calc%omega_grid_w(1:n))
    call print_log( &
        "Initialized a radial integration grid of "//trim(tostr(n))//" points." &
    )
    call print_log( &
        "Relative quadrature error in C6 of carbon atom: "// &
        trim(tostr(test_frequency_grid(calc))) &
    )
end subroutine


real(8) function test_frequency_grid(calc) result(error)
    type(mbd_calc), intent(in) :: calc
    real(8) :: alpha(0:calc%n_freq, 1)

    alpha = alpha_dynamic_ts(calc, (/ 21.d0 /), omega_eff((/ 99.5d0 /), (/ 21.d0 /)))
    error = abs(get_total_C6_from_alpha(calc, alpha)/99.5d0-1.d0)
end function


subroutine get_omega_grid(n, L, x, w)
    integer, intent(in) :: n
    real(8), intent(in) :: L
    real(8), intent(out) :: x(n), w(n)

    call gauss_legendre(n, x, w)
    w = 2*L/(1-x)**2*w
    x = L*(1+x)/(1-x)
    w = w(n:1:-1)
    x = x(n:1:-1)
end subroutine get_omega_grid


subroutine gauss_legendre(n, r, w)
    use mbd_interface, only: legendre_precision

    integer, intent(in) :: n
    real(8), intent(out) :: r(n), w(n)

    integer, parameter :: q = legendre_precision
    integer, parameter :: n_iter = 1000
    real(q) :: x, f, df, dx
    integer :: k, iter, i
    real(q) :: Pk(0:n), Pk1(0:n-1), Pk2(0:n-2)

    if (n == 1) then
        r(1) = 0.d0
        w(1) = 2.d0
        return
    end if
    Pk2(0) = 1._q  ! k = 0
    Pk1(0:1) = (/ 0._q, 1._q /)  ! k = 1
    do k = 2, n
        Pk(0:k) = ((2*k-1)*(/ 0.0_q, Pk1(0:k-1) /)-(k-1)*(/ Pk2(0:k-2), 0._q, 0._q /))/k
        if (k < n) then
            Pk2(0:k-1) = Pk1(0:k-1)
            Pk1(0:k) = Pk(0:k)
        end if
    end do
    ! now Pk contains k-th Legendre polynomial
    do i = 1, n
        x = cos(pi*(i-0.25_q)/(n+0.5_q))
        do iter = 1, n_iter
            df = 0._q
            f = Pk(n)
            do k = n-1, 0, -1
                df = f + x*df
                f = Pk(k) + x*f
            end do
            dx = f/df
            x = x-dx
            if (abs(dx) < 10*epsilon(dx)) exit
        end do
        r(i) = dble(x)
        w(i) = dble(2/((1-x**2)*df**2))
    end do
end subroutine


subroutine init_eqi_grid(calc, n, a, b)
    type(mbd_calc), intent(inout) :: calc
    integer, intent(in) :: n
    real(8), intent(in) :: a, b

    real(8) :: delta
    integer :: i

    if (allocated(calc%omega_grid)) deallocate(calc%omega_grid)
    if (allocated(calc%omega_grid_w)) deallocate(calc%omega_grid_w)
    allocate (calc%omega_grid(0:n))
    allocate (calc%omega_grid_w(0:n))
    calc%omega_grid(0) = 0.d0
    calc%omega_grid_w(0) = 0.d0
    delta = (b-a)/n
    calc%omega_grid(1:n) = (/ (a+delta/2+i*delta, i = 0, n-1) /)
    calc%omega_grid_w(1:n) = delta
end subroutine


function run_scs(sys, alpha, damp) result(alpha_scs)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha(0:, :)
    type(mbd_damping), intent(in) :: damp
    real(8) :: alpha_scs(0:ubound(alpha, 1), size(alpha, 2))

    type(mbd_relay) :: alpha_full
    integer :: i_grid_omega
    logical :: is_parallel, mute

    is_parallel = sys%calc%parallel
    mute = sys%calc%mute

    sys%calc%parallel = .false.

    do i_grid_omega = 0, sys%calc%n_freq
        ! MPI code begin
        if (is_parallel) then
            if (sys%calc%my_task /= modulo(i_grid_omega, sys%calc%n_tasks)) cycle
        end if
        ! MPI code end
        alpha_full = screened_alpha(sys, alpha(i_grid_omega, :), damp)
        alpha_scs(i_grid_omega, :) = contract_polarizability(alpha_full%re)
        sys%calc%mute = .true.
    end do
    ! MPI code begin
    if (is_parallel) then
        call sync_sum(alpha_scs)
    end if
    ! MPI code end

    sys%calc%parallel = is_parallel
    sys%calc%mute = mute
end function run_scs


type(mbd_relay) function screened_alpha(sys, alpha, damp, k_point, lam)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha(:)
    type(mbd_damping), intent(in) :: damp
    real(8), intent(in), optional :: k_point(3)
    real(8), intent(in), optional :: lam

    integer :: i_atom, i_xyz, i
    type(mbd_damping) :: damp_local

    damp_local = damp
    damp_local%sigma = get_sigma_selfint(sys%calc, alpha)
    screened_alpha = dipole_matrix(sys, damp_local, k_point)
    if (present(lam)) then
        if (present(k_point)) then
            screened_alpha%cplx = lam*screened_alpha%cplx
        else
            screened_alpha%re = lam*screened_alpha%re
        end if
    end if
    if (present(k_point)) then
        do i_atom = 1, size(sys%coords, 1)
            do i_xyz = 1, 3
                i = 3*(i_atom-1)+i_xyz
                screened_alpha%cplx(i, i) = screened_alpha%cplx(i, i) &
                    + 1.d0/alpha(i_atom)
            end do
        end do
    else
        do i_atom = 1, size(sys%coords, 1)
            do i_xyz = 1, 3
                i = 3*(i_atom-1)+i_xyz
                screened_alpha%re(i, i) = screened_alpha%re(i, i) &
                    + 1.d0/alpha(i_atom)
            end do
        end do
    end if
    call ts(sys%calc, 32)
    if (present(k_point)) then
        ! TODO this needs to be implemented in linalg and switched
        call invert(screened_alpha%cplx)
    else
        call sinvert(screened_alpha%re)
    end if
    call ts(sys%calc, -32)
end function


function get_mbd_energy(sys, alpha_0, omega, damp) result(ene)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    type(mbd_damping), intent(in) :: damp
    real(8) :: ene

    logical :: is_parallel, do_rpa, is_reciprocal, is_crystal
    real(8), allocatable :: alpha(:, :)

    is_parallel = sys%calc%parallel
    is_crystal = sys%periodic
    do_rpa = sys%do_rpa
    is_reciprocal = sys%do_reciprocal
    if (.not. is_crystal) then
        if (.not. do_rpa) then
            ene = get_single_mbd_energy(sys, alpha_0, omega, damp)
        else
            allocate (alpha(0:sys%calc%n_freq, size(alpha_0)))
            alpha = alpha_dynamic_ts(sys%calc, alpha_0, omega)
            ene = get_single_rpa_energy(sys, alpha, damp)
            deallocate (alpha)
        end if
    else
        if (is_reciprocal) then
            ene = get_reciprocal_mbd_energy(sys, alpha_0, omega, damp)
        else
            ene = get_supercell_mbd_energy(sys, alpha_0, omega, damp)
        end if
    end if
end function get_mbd_energy


real(8) function get_supercell_mbd_energy(sys, alpha_0, omega, damp) result(ene)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    type(mbd_damping), intent(in) :: damp

    logical :: do_rpa
    real(8) :: R_cell(3)
    integer :: i_atom, i
    integer :: i_cell
    integer :: idx_cell(3), n_cells

    real(8), allocatable :: &
        xyz_super(:, :), alpha_0_super(:), omega_super(:), &
        R_vdw_super(:), alpha_ts_super(:, :)
    type(mbd_system) :: sys_super
    type(mbd_damping) :: damp_super

    do_rpa = sys%do_rpa

    sys_super%calc = sys%calc
    sys_super%work = sys%work
    n_cells = product(sys%supercell)
    do i = 1, 3
        sys_super%lattice(i, :) = sys%lattice(i, :)*sys%supercell(i)
    end do
    allocate (sys_super%coords(n_cells*size(sys%coords, 1), 3))
    allocate (alpha_0_super(n_cells*size(alpha_0)))
    allocate (alpha_ts_super(0:sys%calc%n_freq, n_cells*size(alpha_0)))
    allocate (omega_super(n_cells*size(omega)))
    if (allocated(damp%r_vdw)) allocate (damp_super%r_vdw(n_cells*size(damp%r_vdw)))
    idx_cell = (/ 0, 0, -1 /)
    do i_cell = 1, n_cells
        call shift_cell(idx_cell, (/ 0, 0, 0 /), sys%supercell-1)
        R_cell = matmul(idx_cell, sys%lattice)
        do i_atom = 1, size(sys%coords, 1)
            i = (i_cell-1)*size(sys%coords, 1)+i_atom
            sys_super%coords(i, :) = sys%coords(i_atom, :)+R_cell
            alpha_0_super(i) = alpha_0(i_atom)
            omega_super(i) = omega(i_atom)
            if (allocated(damp%R_vdw)) then
                damp_super%R_vdw(i) = damp%R_vdw(i_atom)
            end if
        end do
    end do
    if (do_rpa) then
        alpha_ts_super = alpha_dynamic_ts(sys%calc, alpha_0_super, omega_super)
        ene = get_single_rpa_energy( &
            sys_super, alpha_ts_super, damp_super &
        )
    else
        ene = get_single_mbd_energy( &
            sys_super, alpha_0_super, omega_super, damp_super &
        )
    end if
    deallocate (xyz_super)
    deallocate (alpha_0_super)
    deallocate (alpha_ts_super)
    deallocate (omega_super)
    deallocate (R_vdw_super)
    ene = ene/n_cells
    if (sys%work%get_rpa_orders) then
        sys%work%rpa_orders =sys_super%work%rpa_orders/n_cells
    end if
end function get_supercell_mbd_energy
    

real(8) function get_single_mbd_energy(sys, alpha_0, omega, damp) result(ene)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    type(mbd_damping), intent(in) :: damp

    type(mbd_relay) :: relay
    real(8), allocatable :: eigs(:)
    integer :: i_atom, j_atom, i_xyz, i, j
    integer :: n_negative_eigs
    logical :: is_parallel

    is_parallel = sys%calc%parallel

    allocate (eigs(3*size(sys%coords, 1)))
    ! relay%re = T
    relay = dipole_matrix(sys, damp)
    do i_atom = 1, size(sys%coords, 1)
        do j_atom = i_atom, size(sys%coords, 1)
            i = 3*(i_atom-1)
            j = 3*(j_atom-1)
            relay%re(i+1:i+3, j+1:j+3) = & ! relay%re = sqrt(a*a)*w*w*T
                omega(i_atom)*omega(j_atom) &
                *sqrt(alpha_0(i_atom)*alpha_0(j_atom))* &
                relay%re(i+1:i+3, j+1:j+3)
        end do
    end do
    do i_atom = 1, size(sys%coords, 1)
        do i_xyz = 1, 3
            i = 3*(i_atom-1)+i_xyz
            relay%re(i, i) = relay%re(i, i)+omega(i_atom)**2
            ! relay%re = w^2+sqrt(a*a)*w*w*T
        end do
    end do
    call ts(sys%calc, 21)
    if (.not. is_parallel .or. sys%calc%my_task == 0) then
        if (sys%work%get_modes) then
            call sdiagonalize('V', relay%re, eigs)
            sys%work%modes = relay%re
        else
            call sdiagonalize('N', relay%re, eigs)
        end if
    end if
    ! MPI code begin
    if (is_parallel) then
        call broadcast(relay%re)
        call broadcast(eigs)
    end if
    ! MPI code end
    call ts(sys%calc, -21)
    if (sys%work%get_eigs) then
        sys%work%mode_enes = sqrt(eigs)
        where (eigs < 0) sys%work%mode_enes = 0.d0
    end if
    n_negative_eigs = count(eigs(:) < 0)
    if (n_negative_eigs > 0) then
        call print_warning( &
            "CDM Hamiltonian has " // trim(tostr(n_negative_eigs)) // &
            " negative eigenvalues" &
        )
        if (sys%calc%param%zero_negative_eigs) where (eigs < 0) eigs = 0.d0
    end if
    ene = 1.d0/2*sum(sqrt(eigs))-3.d0/2*sum(omega)
end function get_single_mbd_energy


real(8) function get_reciprocal_mbd_energy(sys, alpha_0, omega, damp) result(ene)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    type(mbd_damping), intent(in) :: damp

    logical :: &
        is_parallel, do_rpa, mute
    integer :: i_kpt, n_kpts, n_atoms
    real(8) :: k_point(3), alpha_ts(0:sys%calc%n_freq, size(sys%coords, 1))

    n_atoms = size(sys%coords, 1)
    sys%work%k_pts = make_k_grid( &
        make_g_grid(sys%calc, sys%k_grid(1), sys%k_grid(2), sys%k_grid(3)), sys%lattice &
    )
    n_kpts = size(sys%work%k_pts, 1)
    is_parallel = sys%calc%parallel
    do_rpa = sys%do_rpa
    mute = sys%calc%mute

    sys%calc%parallel = .false.

    alpha_ts = alpha_dynamic_ts(sys%calc, alpha_0, omega)
    ene = 0.d0
    if (sys%work%get_eigs) &
        allocate (sys%work%mode_enes_k(n_kpts, 3*n_atoms), source=0.d0)
    if (sys%work%get_modes) &
        allocate (sys%work%modes_k(n_kpts, 3*n_atoms, 3*n_atoms), source=(0.d0, 0.d0))
    if (sys%work%get_rpa_orders) &
        allocate (sys%work%rpa_orders_k(n_kpts, sys%calc%param%rpa_order_max), source=0.d0)
    do i_kpt = 1, n_kpts
        ! MPI code begin
        if (is_parallel) then
            if (sys%calc%my_task /= modulo(i_kpt, sys%calc%n_tasks)) cycle
        end if
        ! MPI code end
        k_point = sys%work%k_pts(i_kpt, :)
        sys%work%i_kpt = i_kpt
        if (do_rpa) then
            ene = ene + get_single_reciprocal_rpa_ene(sys, alpha_ts, k_point, damp)
        else
            ene = ene + get_single_reciprocal_mbd_ene(sys, alpha_0, omega, k_point, damp)
        end if
        sys%calc%mute = .true.
    end do ! k_point loop
    ! MPI code begin
    if (is_parallel) then
        call sync_sum(ene)
        if (sys%work%get_eigs) call sync_sum(sys%work%mode_enes_k)
        if (sys%work%get_modes) call sync_sum(sys%work%modes_k)
        if (sys%work%get_rpa_orders) call sync_sum(sys%work%rpa_orders_k)
    end if
    ! MPI code end
    ene = ene/size(sys%work%k_pts, 1)
    if (sys%work%get_rpa_orders) sys%work%rpa_orders = sys%work%rpa_orders/n_kpts

    sys%calc%parallel = is_parallel
    sys%calc%mute = mute
end function get_reciprocal_mbd_energy


real(8) function get_single_reciprocal_mbd_ene(sys, alpha_0, omega, k_point, damp) result(ene)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    real(8), intent(in) :: k_point(3)
    type(mbd_damping), intent(in) :: damp


    type(mbd_relay) :: relay
    real(8), allocatable :: eigs(:)
    integer :: i_atom, j_atom, i_xyz, i, j
    integer :: n_negative_eigs
    logical :: is_parallel

    is_parallel = sys%calc%parallel

    allocate (eigs(3*size(sys%coords, 1)))
    ! relay = T
    relay = dipole_matrix(sys, damp, k_point)
    do i_atom = 1, size(sys%coords, 1)
        do j_atom = i_atom, size(sys%coords, 1)
            i = 3*(i_atom-1)
            j = 3*(j_atom-1)
            relay%cplx(i+1:i+3, j+1:j+3) = & ! relay = sqrt(a*a)*w*w*T
                omega(i_atom)*omega(j_atom) &
                *sqrt(alpha_0(i_atom)*alpha_0(j_atom))* &
                relay%cplx(i+1:i+3, j+1:j+3)
        end do
    end do
    do i_atom = 1, size(sys%coords, 1)
        do i_xyz = 1, 3
            i = 3*(i_atom-1)+i_xyz
            relay%cplx(i, i) = relay%cplx(i, i)+omega(i_atom)**2
            ! relay = w^2+sqrt(a*a)*w*w*T
        end do
    end do
    call ts(sys%calc, 22)
    if (.not. is_parallel .or. sys%calc%my_task == 0) then
        if (sys%work%get_modes) then
            call sdiagonalize('V', relay%cplx, eigs)
            sys%work%modes_k(sys%work%i_kpt, :, :) = relay%cplx
        else
            call sdiagonalize('N', relay%cplx, eigs)
        end if
    end if
    ! MPI code begin
    if (is_parallel) then
        call broadcast(relay%cplx)
        call broadcast(eigs)
    end if
    ! MPI code end
    call ts(sys%calc, -22)
    if (sys%work%get_eigs) then
        sys%work%mode_enes = sqrt(eigs)
        where (eigs < 0) sys%work%mode_enes = 0.d0
    end if
    n_negative_eigs = count(eigs(:) < 0)
    if (n_negative_eigs > 0) then
        call print_warning( &
            "CDM Hamiltonian has " // trim(tostr(n_negative_eigs)) // &
            " negative eigenvalues" &
        )
        if (sys%calc%param%zero_negative_eigs) where (eigs < 0) eigs = 0.d0
    end if
    ene = 1.d0/2*sum(sqrt(eigs))-3.d0/2*sum(omega)
end function get_single_reciprocal_mbd_ene


real(8) function get_single_rpa_energy(sys, alpha, damp) result(ene)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha(0:, :)
    type(mbd_damping), intent(in) :: damp

    type(mbd_relay) :: relay, AT
    complex(8), allocatable :: eigs(:)
    integer :: i_atom, i_grid_omega, i
    integer :: n_order, n_negative_eigs
    logical :: is_parallel, mute
    type(mbd_damping) :: damp_alpha

    is_parallel = sys%calc%parallel
    mute = sys%calc%mute

    sys%calc%parallel = .false.

    ene = 0.d0
    damp_alpha = damp
    allocate (eigs(3*size(sys%coords, 1)))
    do i_grid_omega = 0, sys%calc%n_freq
        ! MPI code begin
        if (is_parallel) then
            if (sys%calc%my_task /= modulo(i_grid_omega, sys%calc%n_tasks)) cycle
        end if
        ! MPI code end
        damp_alpha%sigma = get_sigma_selfint(sys%calc, alpha(i_grid_omega, :))
        ! relay = T
        relay = dipole_matrix(sys, damp_alpha)
        do i_atom = 1, size(sys%coords, 1)
            i = 3*(i_atom-1)
            relay%re(i+1:i+3, :i) = &
                alpha(i_grid_omega, i_atom)*transpose(relay%re(:i, i+1:i+3))
        end do
        do i_atom = 1, size(sys%coords, 1)
            i = 3*(i_atom-1)
            relay%re(i+1:i+3, i+1:) = &
                alpha(i_grid_omega, i_atom)*relay%re(i+1:i+3, i+1:)
        end do
        ! relay = alpha*T
        if (sys%work%get_rpa_orders) AT = relay
        do i = 1, 3*size(sys%coords, 1)
            relay%re(i, i) = 1.d0+relay%re(i, i) ! relay = 1+alpha*T
        end do
        call ts(sys%calc, 23)
        call diagonalize('N', relay%re, eigs)
        call ts(sys%calc, -23)
        ! The count construct won't work here due to a bug in Cray compiler
        ! Has to manually unroll the counting
        n_negative_eigs = 0
        do i = 1, size(eigs)
           if (dble(eigs(i)) < 0) n_negative_eigs = n_negative_eigs + 1
        end do
        if (n_negative_eigs > 0) then
            call print_warning("1+AT matrix has " &
                //trim(tostr(n_negative_eigs))//" negative eigenvalues")
        end if
        ene = ene+1.d0/(2*pi)*sum(log(dble(eigs)))*sys%calc%omega_grid_w(i_grid_omega)
        if (sys%work%get_rpa_orders) then
            call ts(sys%calc, 24)
            call diagonalize('N', AT%re, eigs)
            call ts(sys%calc, -24)
            allocate (sys%work%rpa_orders(sys%calc%param%rpa_order_max))
            do n_order = 2, sys%calc%param%rpa_order_max
                sys%work%rpa_orders(n_order) = sys%work%rpa_orders(n_order) &
                    +(-1.d0/(2*pi)*(-1)**n_order &
                    *sum(dble(eigs)**n_order)/n_order) &
                    *sys%calc%omega_grid_w(i_grid_omega)
            end do
        end if
        sys%calc%mute = .true.
    end do
    if (is_parallel) then
        call sync_sum(ene)
        if (sys%work%get_rpa_orders) then
            call sync_sum(sys%work%rpa_orders)
        end if
    end if
end function get_single_rpa_energy


real(8) function get_single_reciprocal_rpa_ene(sys, alpha, k_point, damp) result(ene)
    type(mbd_system), intent(inout) :: sys
    real(8), intent(in) :: alpha(0:, :)
    real(8), intent(in) :: k_point(3)
    type(mbd_damping), intent(in) :: damp

    type(mbd_relay) :: relay, AT
    complex(8), allocatable :: eigs(:)
    integer :: i_atom, i_grid_omega, i
    integer :: n_order, n_negative_eigs
    logical :: is_parallel, mute
    type(mbd_damping) :: damp_alpha

    is_parallel = sys%calc%parallel
    mute = sys%calc%mute

    sys%calc%parallel = .false.

    ene = 0.d0
    damp_alpha = damp
    allocate (eigs(3*size(sys%coords, 1)))
    do i_grid_omega = 0, sys%calc%n_freq
        ! MPI code begin
        if (is_parallel) then
            if (sys%calc%my_task /= modulo(i_grid_omega, sys%calc%n_tasks)) cycle
        end if
        ! MPI code end
        damp_alpha%sigma = get_sigma_selfint(sys%calc, alpha(i_grid_omega, :))
        ! relay = T
        relay = dipole_matrix(sys, damp_alpha, k_point)
        do i_atom = 1, size(sys%coords, 1)
            i = 3*(i_atom-1)
            relay%cplx(i+1:i+3, :i) = &
                alpha(i_grid_omega, i_atom)*conjg(transpose(relay%cplx(:i, i+1:i+3)))
        end do
        do i_atom = 1, size(sys%coords, 1)
            i = 3*(i_atom-1)
            relay%cplx(i+1:i+3, i+1:) = &
                alpha(i_grid_omega, i_atom)*relay%cplx(i+1:i+3, i+1:)
        end do
        ! relay = alpha*T
        if (sys%work%get_rpa_orders) AT = relay
        do i = 1, 3*size(sys%coords, 1)
            relay%cplx(i, i) = 1.d0+relay%cplx(i, i) ! relay = 1+alpha*T
        end do
        call ts(sys%calc, 25)
        call diagonalize('N', relay%cplx, eigs)
        call ts(sys%calc, -25)
        ! The count construct won't work here due to a bug in Cray compiler
        ! Has to manually unroll the counting
        n_negative_eigs = 0
        do i = 1, size(eigs)
           if (dble(eigs(i)) < 0) n_negative_eigs = n_negative_eigs + 1
        end do
        if (n_negative_eigs > 0) then
            call print_warning("1+AT matrix has " &
                //trim(tostr(n_negative_eigs))//" negative eigenvalues")
        end if
        ene = ene+1.d0/(2*pi)*dble(sum(log(eigs)))*sys%calc%omega_grid_w(i_grid_omega)
        if (sys%work%get_rpa_orders) then
            call ts(sys%calc, 26)
            call diagonalize('N', AT%cplx, eigs)
            call ts(sys%calc, -26)
            do n_order = 2, sys%calc%param%rpa_order_max
                sys%work%rpa_orders_k(sys%work%i_kpt, n_order) = &
                    sys%work%rpa_orders_k(sys%work%i_kpt, n_order) &
                    +(-1.d0)/(2*pi)*(-1)**n_order &
                    *dble(sum(eigs**n_order))/n_order &
                    *sys%calc%omega_grid_w(i_grid_omega)
            end do
        end if
        sys%calc%mute = .true.
    end do
    if (is_parallel) then
        call sync_sum(ene)
        if (sys%work%get_rpa_orders) then
            call sync_sum(sys%work%rpa_orders_k(sys%work%i_kpt, :))
        end if
    end if

    sys%calc%parallel = is_parallel
    sys%calc%mute = mute
end function get_single_reciprocal_rpa_ene


! function mbd_nbody( &
!         xyz, &
!         alpha_0, &
!         omega, &
!         version, &
!         R_vdw, beta, a, &
!         calc%my_task, calc%n_tasks) &
!         result(ene_orders)
!     real(8), intent(in) :: &
!         xyz(:, :), &
!         alpha_0(size(xyz, 1)), &
!         omega(size(xyz, 1)), &
!         R_vdw(size(xyz, 1)), &
!         beta, a
!     character(len=*), intent(in) :: version
!     integer, intent(in), optional :: calc%my_task, calc%n_tasks
!     real(8) :: ene_orders(20)
!
!     integer :: &
!         multi_index(calc%param%mbd_nbody_max), i_body, j_body, i_tuple, &
!         i_atom_ind, j_atom_ind, i_index
!     real(8) :: ene
!     logical :: is_parallel
!     
!     is_parallel = .false.
!     if (present(calc%n_tasks)) then
!         if (calc%n_tasks > 0) then
!             is_parallel = .true.
!         end if
!     end if
!     ene_orders(:) = 0.d0
!     do i_body = 2, calc%param%mbd_nbody_max
!         i_tuple = 0
!         multi_index(1:i_body-1) = 1
!         multi_index(i_body:calc%param%mbd_nbody_max) = 0
!         do
!             multi_index(i_body) = multi_index(i_body)+1
!             do i_index = i_body, 2, -1
!                 if (multi_index(i_index) > size(xyz, 1)) then
!                     multi_index(i_index) = 1
!                     multi_index(i_index-1) = multi_index(i_index-1)+1
!                 end if
!             end do
!             if (multi_index(1) > size(xyz, 1)) exit
!             if (any(multi_index(1:i_body-1)-multi_index(2:i_body) >= 0)) cycle
!             i_tuple = i_tuple+1
!             if (is_parallel) then
!                 if (calc%my_task /= modulo(i_tuple, calc%n_tasks)) cycle
!             end if
!             ene = get_mbd_energy( &
!                 xyz(multi_index(1:i_body), :), &
!                 alpha_0(multi_index(1:i_body)), &
!                 omega(multi_index(1:i_body)), &
!                 version, &
!                 R_vdw(multi_index(1:i_body)), &
!                 beta, a)
!             ene_orders(i_body) = ene_orders(i_body) &
!                 +ene+3.d0/2*sum(omega(multi_index(1:i_body)))
!         end do ! i_tuple
!     end do ! i_body
!     if (is_parallel) then
!         call sync_sum(ene_orders, size(ene_orders))
!     end if
!     ene_orders(1) = 3.d0/2*sum(omega)
!     do i_body = 2, min(calc%param%mbd_nbody_max, size(xyz, 1))
!         do j_body = 1, i_body-1
!             ene_orders(i_body) = ene_orders(i_body) &
!                 -nbody_coeffs(j_body, i_body, size(xyz, 1))*ene_orders(j_body)
!         end do
!     end do
!     ene_orders(1) = sum(ene_orders(2:calc%param%mbd_nbody_max))
! end function mbd_nbody


function eval_mbd_nonint_density(calc, pts, xyz, charges, masses, omegas) result(rho)
    type(mbd_calc), intent(in) :: calc
    real(8), intent(in) :: &
        pts(:, :), &
        xyz(:, :), &
        charges(:), &
        masses(:), &
        omegas(:)
    real(8) :: rho(size(pts, 1))

    integer :: i_pt, i_atom, n_atoms
    real(8), dimension(size(xyz, 1)) :: pre, kernel, rsq

    pre = charges*(masses*omegas/pi)**(3.d0/2)
    kernel = masses*omegas
    n_atoms = size(xyz, 1)
    rho(:) = 0.d0
    do i_pt = 1, size(pts, 1)
        if (calc%my_task /= modulo(i_pt, calc%n_tasks)) cycle
        forall (i_atom = 1:n_atoms)
            rsq(i_atom) = sum((pts(i_pt, :)-xyz(i_atom, :))**2)
        end forall
        rho(i_pt) = sum(pre*exp(-kernel*rsq))
    end do
    call sync_sum(rho)
end function


function eval_mbd_int_density(calc, pts, xyz, charges, masses, omegas, modes) result(rho)
    type(mbd_calc), intent(in) :: calc
    real(8), intent(in) :: &
        pts(:, :), &
        xyz(:, :), &
        charges(:), &
        masses(:), &
        omegas(:), &
        modes(:, :)
    real(8) :: rho(size(pts, 1))

    integer :: i_pt, i_atom, n_atoms, i, i_xyz, j_xyz
    integer :: self(3), other(3*(size(xyz, 1)-1))
    real(8) :: &
        pre(size(xyz, 1)), &
        factor(size(xyz, 1)), &
        rdiffsq(3, 3), &
        omegas_p(3*size(xyz, 1), 3*size(xyz, 1)), &
        kernel(3, 3, size(xyz, 1)), &
        rdiff(3)

    omegas_p = matmul(matmul(modes, diag(omegas)), transpose(modes))
    n_atoms = size(xyz, 1)
    kernel(:, :, :) = 0.d0
    pre(:) = 0.d0
    do i_atom = 1, n_atoms
        if (calc%my_task /= modulo(i_atom, calc%n_tasks)) cycle
        self(:) = (/ (3*(i_atom-1)+i, i = 1, 3) /)
        other(:) = (/ (i, i = 1, 3*(i_atom-1)),  (i, i = 3*i_atom+1, 3*n_atoms) /)
        kernel(:, :, i_atom) = masses(i_atom) &
            *(omegas_p(self, self) &
                -matmul(matmul(omegas_p(self, other), inverted(omegas_p(other, other))), &
                    omegas_p(other, self)))
        pre(i_atom) = charges(i_atom)*(masses(i_atom)/pi)**(3.d0/2) &
            *sqrt(product(omegas)/product(sdiagonalized(omegas_p(other, other))))
    end do
    call sync_sum(kernel)
    call sync_sum(pre)
    rho(:) = 0.d0
    do i_pt = 1, size(pts, 1)
        if (calc%my_task /= modulo(i_pt, calc%n_tasks)) cycle
        do i_atom = 1, n_atoms
            rdiff(:) = pts(i_pt, :)-xyz(i_atom, :)
            forall (i_xyz = 1:3, j_xyz = 1:3)
                rdiffsq(i_xyz, j_xyz) = rdiff(i_xyz)*rdiff(j_xyz)
            end forall
            factor(i_atom) = sum(kernel(:, :, i_atom)*rdiffsq(:, :))
        end do
        rho(i_pt) = sum(pre*exp(-factor))
    end do
    call sync_sum(rho)
end function


function nbody_coeffs(k, m, N) result(a)
    integer, intent(in) :: k, m, N
    integer :: a

    integer :: i

    a = 1
    do i = N-m+1, N-k
        a = a*i
    end do
    do i = 1, m-k
        a = a/i
    end do
end function nbody_coeffs


function contract_polarizability(alpha_3n_3n) result(alpha_n)
    real(8), intent(in) :: alpha_3n_3n(:, :)
    real(8) :: alpha_n(size(alpha_3n_3n, 1)/3)

    integer :: i_atom, i_xyz, dim_3n

    dim_3n = size(alpha_3n_3n, 1)
    alpha_n(:) = 0.d0
    do i_atom = 1, size(alpha_n)
        associate (A => alpha_n(i_atom))
            do i_xyz = 1, 3
                ! this convoluted contraction is necessary because alpha_3n_3n is
                ! calucated as upper triangular
                A = A + sum(alpha_3n_3n(i_xyz:3*i_atom:3, 3*(i_atom-1)+i_xyz))
                A = A + sum(alpha_3n_3n(3*(i_atom-1)+i_xyz, 3*i_atom+i_xyz:dim_3n:3))
            end do
        end associate
    end do
    alpha_n = alpha_n/3
end function contract_polarizability


function T_bare(rxyz) result(T)
    real(8), intent(in) :: rxyz(3)
    real(8) :: T(3, 3)

    integer :: i, j
    real(8) :: r_sq, r_5

    r_sq = sum(rxyz(:)**2)
    r_5 = sqrt(r_sq)**5
    do i = 1, 3
        T(i, i) = (3.d0*rxyz(i)**2-r_sq)/r_5
        do j = i+1, 3
            T(i, j) = 3.d0*rxyz(i)*rxyz(j)/r_5
            T(j, i) = T(i, j)
        end do
    end do
    T = -T
end function


type(dip33) function T_bare_v2(r, deriv) result(T)
    real(8), intent(in) :: r(3)
    logical, intent(in) :: deriv

    integer :: a, b, c
    real(8) :: r_1, r_2, r_5, r_7

    r_2 = sum(r**2)
    r_1 = sqrt(r_2)
    r_5 = r_1**5
    forall (a = 1:3)
        T%val(a, a) = (-3*r(a)**2+r_2)/r_5
        forall (b = a+1:3)
            T%val(a, b) = -3*r(a)*r(b)/r_5
            T%val(b, a) = T%val(a, b)
        end forall
    end forall
    if (deriv) then
        r_7 = r_1**7
        forall (a = 1:3)
            T%dr(a, a, a) = -3*(3*r(a)/r_5-5*r(a)**3/r_7)
            forall (b = a+1:3)
                T%dr(a, a, b) = -3*(r(b)/r_5-5*r(a)**2*r(b)/r_7)
                T%dr(a, b, a) = T%dr(a, a, b)
                T%dr(b, a, a) = T%dr(a, a, b)
                T%dr(b, b, a) = -3*(r(a)/r_5-5*r(b)**2*r(a)/r_7)
                T%dr(b, a, b) = T%dr(b, b, a)
                T%dr(a, b, b) = T%dr(b, b, a)
                forall (c = b+1:3)
                    T%dr(a, b, c) = 15*r(a)*r(b)*r(c)/r_7
                    T%dr(a, c, b) = T%dr(a, b, c)
                    T%dr(b, a, c) = T%dr(a, b, c)
                    T%dr(b, c, a) = T%dr(a, b, c)
                    T%dr(c, a, b) = T%dr(a, b, c)
                    T%dr(c, b, a) = T%dr(a, b, c)
                end forall
            end forall
        end forall
    end if
end function


real(8) function B_erfc(r, a) result(B)
    real(8), intent(in) :: r, a

    B = (erfc(a*r)+(2*a*r/sqrt(pi))*exp(-(a*r)**2))/r**3
end function


real(8) elemental function C_erfc(r, a) result(C)
    real(8), intent(in) :: r, a

    C = (3*erfc(a*r)+(2*a*r/sqrt(pi))*(3.d0+2*(a*r)**2)*exp(-(a*r)**2))/r**5
end function


function T_erfc(rxyz, alpha) result(T)
    real(8), intent(in) :: rxyz(3), alpha
    real(8) :: T(3, 3)

    integer :: i, j
    real(8) :: r, B, C

    r = sqrt(sum(rxyz(:)**2))
    B = B_erfc(r, alpha)
    C = C_erfc(r, alpha)
    do i = 1, 3
        do j = i, 3
            T(i, j) = -C*rxyz(i)*rxyz(j)
            if (i /= j) T(j, i) = T(i, j)
        end do
        T(i, i) = T(i, i)+B
    end do
end function


type(scalar) function damping_fermi(r, s_vdw, d, deriv) result(f)
    real(8), intent(in) :: r(3)
    real(8), intent(in) :: s_vdw
    real(8), intent(in) :: d
    logical, intent(in) :: deriv

    real(8) :: pre, eta, r_1

    r_1 = sqrt(sum(r**2))
    eta = r_1/s_vdw
    f%val = 1.d0/(1+exp(-d*(eta-1)))
    pre = d/(2+2*cosh(d-d*eta))
    if (deriv) then
        f%dr = pre*r/(r_1*s_vdw)
        f%dvdw = -pre*r_1/s_vdw**2
    end if
end function


type(dip33) function T_damped(sys, f, T, sr)
    type(mbd_system), intent(in) :: sys
    type(scalar), intent(in) :: f
    type(dip33), intent(in) :: T
    logical, intent(in) :: sr  ! true: f, false: 1-f

    real(8) :: pre
    integer :: sgn, c

    if (sr) then
        pre = 1-f%val
        sgn = -1
    else
        pre = f%val
        sgn = 1
    end if
    T_damped%val = pre*T%val
    if (sys%do_force) then
        forall (c = 1:3) T_damped%dr(:, :, c) = sgn*f%dr(c)*T%val
        T_damped%dr = T_damped%dr + pre*T%dr
        T_damped%dvdw = sgn*f%dvdw*T%val
        T_damped%has_vdw = .true.
        if (T%has_sigma) then
            T_damped%dsigma = pre*T%dsigma
            T_damped%has_sigma = .true.
        end if
    end if
end function


type(dip33) function T_erf_coulomb(r, sigma, deriv) result(T)
    real(8), intent(in) :: r(3)
    real(8), intent(in) :: sigma
    logical, intent(in) :: deriv

    real(8) :: theta, erf_theta, r_5, r_1, zeta
    type(dip33) :: bare
    real(8) :: tmp33(3, 3), tmp333(3, 3, 3), rr_r5(3, 3)
    integer :: a, c

    bare = T_bare_v2(r, deriv)
    r_1 = sqrt(sum(r**2))
    r_5 = r_1**5
    rr_r5 = (r.cprod.r)/r_5
    zeta = r_1/sigma
    theta = 2*zeta/sqrt(pi)*exp(-zeta**2)
    erf_theta = erf(zeta)-theta
    T%val = erf_theta*bare%val+2*(zeta**2)*theta*rr_r5
    if (deriv) then
        tmp33 = 2*zeta*theta*(bare%val+(3-2*zeta**2)*rr_r5)
        forall (c = 1:3) T%dr(:, :, c) = tmp33*r(c)/(r_1*sigma)
        tmp333 = bare%dr/3
        forall (a = 1:3, c = 1:3) tmp333(a, a, c) = tmp333(a, a, c) + r(c)/r_5
        T%dr = T%dr + erf_theta*bare%dr-2*(zeta**2)*theta*tmp333
        T%has_sigma = .true.
        T%dsigma = -tmp33*r_1/sigma**2
    end if
end function


function T_1mexp_coulomb(rxyz, sigma, a) result(T)
    real(8), intent(in) :: rxyz(3), sigma, a
    real(8) :: T(3, 3)

    real(8) :: r_sigma, zeta_1, zeta_2

    r_sigma = (sqrt(sum(rxyz**2))/sigma)**a
    zeta_1 = 1.d0-exp(-r_sigma)-a*r_sigma*exp(-r_sigma)
    zeta_2 = -r_sigma*a*exp(-r_sigma)*(1+a*(-1+r_sigma))
    T = zeta_1*T_bare(rxyz)-zeta_2*(rxyz .cprod. rxyz)/sqrt(sum(rxyz**2))**5
end function


subroutine get_damping_parameters(xc, ts_d, ts_s_r, mbd_scs_a, mbd_ts_a, &
        mbd_ts_erf_beta, mbd_ts_fermi_beta, mbd_rsscs_a, mbd_rsscs_beta)
    character(len=*), intent(in) :: xc
    real(8), intent(out) :: &
        ts_d, ts_s_r, mbd_scs_a, mbd_ts_a, mbd_ts_erf_beta, &
        mbd_ts_fermi_beta, mbd_rsscs_a, mbd_rsscs_beta

    ts_d = 20.d0
    ts_s_r = 1.d0
    mbd_scs_a = 2.d0
    mbd_ts_a = 6.d0
    mbd_ts_erf_beta = 1.d0
    mbd_ts_fermi_beta = 1.d0
    mbd_rsscs_a = 6.d0
    mbd_rsscs_beta = 1.d0
    select case (xc)
        case ("pbe")
            ts_s_r = 0.94d0
            mbd_scs_a = 2.56d0
            mbd_ts_erf_beta = 1.07d0
            mbd_ts_fermi_beta = 0.81d0
            mbd_rsscs_beta = 0.83d0
        case ("pbe0")
            ts_s_r = 0.96d0
            mbd_scs_a = 2.53d0
            mbd_ts_erf_beta = 1.08d0
            mbd_ts_fermi_beta = 0.83d0
            mbd_rsscs_beta = 0.85d0
        case ("hse")
            ts_s_r = 0.96d0
            mbd_scs_a = 2.53d0
            mbd_ts_erf_beta = 1.08d0
            mbd_ts_fermi_beta = 0.83d0
            mbd_rsscs_beta = 0.85d0
        case ("blyp")
            ts_s_r = 0.62d0
        case ("b3lyp")
            ts_s_r = 0.84d0
        case ("revpbe")
            ts_s_r = 0.60d0
        case ("am05")
            ts_s_r = 0.84d0
    endselect
end subroutine get_damping_parameters


elemental function terf(r, r0, a)
    real(8), intent(in) :: r, r0, a
    real(8) :: terf

    terf = 0.5d0*(erf(a*(r+r0))+erf(a*(r-r0)))
end function


function alpha_dynamic_ts(calc, alpha_0, omega) result(alpha)
    type(mbd_calc), intent(in) :: calc
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in) :: omega(:)
    real(8) :: alpha(0:calc%n_freq, size(alpha_0))

    integer :: i_freq

    forall (i_freq = 0:calc%n_freq) &
        alpha(i_freq, :) = alpha_osc(alpha_0, omega, calc%omega_grid(i_freq))
end function


elemental function alpha_osc(alpha_0, omega, u) result(alpha)
    real(8), intent(in) :: alpha_0, omega, u
    real(8) :: alpha

    alpha = alpha_0/(1+(u/omega)**2)
end function


elemental function combine_C6 (C6_i, C6_j, alpha_0_i, alpha_0_j) result(C6_ij)
    real(8), intent(in) :: C6_i, C6_j, alpha_0_i, alpha_0_j
    real(8) :: C6_ij

    C6_ij = 2*C6_i*C6_j/(alpha_0_j/alpha_0_i*C6_i+alpha_0_i/alpha_0_j*C6_j)
end function


elemental function V_to_R(V) result(R)
    real(8), intent(in) :: V
    real(8) :: R

    R = (3.d0*V/(4.d0*pi))**(1.d0/3)
end function


elemental function omega_eff(C6, alpha) result(omega)
    real(8), intent(in) :: C6, alpha
    real(8) :: omega

    omega = 4.d0/3*C6/alpha**2
end function


elemental function get_sigma_selfint(calc, alpha) result(sigma)
    type(mbd_calc), intent(in) :: calc
    real(8), intent(in) :: alpha
    real(8) :: sigma

    sigma = calc%param%mayer_scaling*(sqrt(2.d0/pi)*alpha/3.d0)**(1.d0/3)
end function


function get_C6_from_alpha(calc, alpha) result(C6)
    type(mbd_calc), intent(in) :: calc
    real(8), intent(in) :: alpha(:, :)
    real(8) :: C6(size(alpha, 2))
    integer :: i_atom

    do i_atom = 1, size(alpha, 2)
        C6(i_atom) = 3.d0/pi*sum((alpha(:, i_atom)**2)*calc%omega_grid_w(:))
    end do
end function


function get_total_C6_from_alpha(calc, alpha) result(C6)
    type(mbd_calc), intent(in) :: calc
    real(8), intent(in) :: alpha(:, :)
    real(8) :: C6

    C6 = 3.d0/pi*sum((sum(alpha, 2)**2)*calc%omega_grid_w(:))
end function


function supercell_circum(calc, uc, radius) result(sc)
    type(mbd_calc), intent(in) :: calc
    real(8), intent(in) :: uc(3, 3), radius
    integer :: sc(3)

    real(8) :: ruc(3, 3), layer_sep(3)
    integer :: i

    ruc = 2*pi*inverted(transpose(uc))
    forall (i = 1:3) layer_sep(i) = sum(uc(i, :)*ruc(i, :)/sqrt(sum(ruc(i, :)**2)))
    sc = ceiling(radius/layer_sep+0.5d0)
    where (calc%param%vacuum_axis) sc = 0
end function


subroutine shift_cell(ijk, first_cell, last_cell)
    integer, intent(inout) :: ijk(3)
    integer, intent(in) :: first_cell(3), last_cell(3)

    integer :: i_dim, i

    do i_dim = 3, 1, -1
        i = ijk(i_dim)+1
        if (i <= last_cell(i_dim)) then
            ijk(i_dim) = i
            return
        else
            ijk(i_dim) = first_cell(i_dim)
        end if
    end do
end subroutine


function make_g_grid(calc, n1, n2, n3) result(g_grid)
    type(mbd_calc), intent(in) :: calc
    integer, intent(in) :: n1, n2, n3
    real(8) :: g_grid(n1*n2*n3, 3)

    integer :: g_kpt(3), i_kpt, kpt_range(3)
    real(8) :: g_kpt_shifted(3)

    g_kpt = (/ 0, 0, -1 /)
    kpt_range = (/ n1, n2, n3 /)
    do i_kpt = 1, n1*n2*n3
        call shift_cell (g_kpt, (/ 0, 0, 0 /), kpt_range-1)
        g_kpt_shifted = dble(g_kpt)+calc%param%k_grid_shift
        where (2*g_kpt_shifted > kpt_range)
            g_kpt_shifted = g_kpt_shifted-dble(kpt_range)
        end where
        g_grid(i_kpt, :) = g_kpt_shifted/kpt_range
    end do
end function make_g_grid


function make_k_grid(g_grid, uc) result(k_grid)
    real(8), intent(in) :: g_grid(:, :), uc(3, 3)
    real(8) :: k_grid(size(g_grid, 1), 3)

    integer :: i_kpt
    real(8) :: ruc(3, 3)

    ruc = 2*pi*inverted(transpose(uc))
    do i_kpt = 1, size(g_grid, 1)
        k_grid(i_kpt, :) = matmul(g_grid(i_kpt, :), ruc)
    end do
end function make_k_grid


subroutine ts(calc, id, always)
    type(mbd_calc), intent(inout) :: calc
    integer, intent(in) :: id
    logical, intent(in), optional :: always

    if (calc%tm%measure_time .or. present(always)) then
        call system_clock(calc%tm%ts_cnt, calc%tm%ts_rate, calc%tm%ts_cnt_max)
        if (id > 0) then
            calc%tm%timestamps(id) = calc%tm%timestamps(id)-calc%tm%ts_cnt
        else
            calc%tm%ts_aid = abs(id)
            calc%tm%timestamps(calc%tm%ts_aid) = calc%tm%timestamps(calc%tm%ts_aid)+calc%tm%ts_cnt
            calc%tm%ts_counts(calc%tm%ts_aid) = calc%tm%ts_counts(calc%tm%ts_aid)+1
        end if
    end if
end subroutine ts


function clock_rate() result(rate)
    integer :: cnt, rate, cnt_max

    call system_clock(cnt, rate, cnt_max) 
end function clock_rate


!!! tests !!!

subroutine run_tests()
    use mbd_common, only: diff3, tostr, diff5

    integer :: n_failed, n_all

    n_failed = 0
    n_all = 0
    call exec_test('T_bare derivative', test_T_bare_deriv)
    call exec_test('T_GG derivative explicit', test_T_GG_deriv_expl)
    call exec_test('T_GG derivative implicit', test_T_GG_deriv_impl)
    write (6, *) &
        trim(tostr(n_failed)) // '/' // trim(tostr(n_all)) // ' tests failed'
    if (n_failed /= 0) stop 1

    contains

    subroutine exec_test(test_name, test_routine)
        character(len=*), intent(in) :: test_name
        interface
            subroutine test_routine()
            end subroutine
        end interface

        integer :: n_failed_in

        write (6, '(A,A,A)', advance='no') 'Executing test "', test_name, '"... '
        n_failed_in = n_failed
        call test_routine()
        n_all = n_all + 1
        if (n_failed == n_failed_in) write (6, *) 'OK'
    end subroutine

    subroutine failed()
        n_failed = n_failed + 1
        write (6, *) 'FAILED!'
    end subroutine

    subroutine test_T_bare_deriv()
        real(8) :: r(3), r_diff(3)
        type(dip33) :: T
        real(8) :: diff(3, 3)
        real(8) :: T_diff_anl(3, 3, 3)
        real(8) :: T_diff_num(3, 3, -2:2)
        integer :: a, b, c, i_step
        real(8) :: delta

        delta = 1d-3
        r = [1.12d0, -2.12d0, 0.12d0]
        T = T_bare_v2(r, deriv=.true.)
        T_diff_anl = T%dr(:, :, :)
        do c = 1, 3
            do i_step = -2, 2
                if (i_step == 0) continue
                r_diff = r
                r_diff(c) = r_diff(c)+i_step*delta
                T = T_bare_v2(r_diff, deriv=.false.)
                T_diff_num(:, :, i_step) = T%val
            end do
            forall (a = 1:3, b = 1:3)
                T_diff_num(a, b, 0) = diff5(T_diff_num(a, b, :), delta)
            end forall
            diff = T_diff_num(:, :, 0)-T_diff_anl(:, :, c)
            if (any(abs(diff) > 1d-12)) then
                call failed()
                call print_matrix('delta dT(:, :, ' // trim(tostr(c)) // ')', diff)
                return
            end if
        end do
    end subroutine test_T_bare_deriv

    subroutine test_T_GG_deriv_expl()
        real(8) :: r(3), r_diff(3)
        type(dip33) :: T
        real(8) :: diff(3, 3)
        real(8) :: T_diff_anl(3, 3, 3)
        real(8) :: T_diff_num(3, 3, -2:2)
        integer :: a, b, c, i_step
        real(8) :: delta
        real(8) :: sigma

        delta = 1d-3
        r = [1.02d0, -2.22d0, 0.15d0]
        sigma = 1.2d0
        T = T_erf_coulomb(r, sigma, deriv=.true.)
        T_diff_anl = T%dr
        do c = 1, 3
            do i_step = -2, 2
                if (i_step == 0) continue
                r_diff = r
                r_diff(c) = r_diff(c)+i_step*delta
                T = T_erf_coulomb(r_diff, sigma, deriv=.false.)
                T_diff_num(:, :, i_step) = T%val
            end do
            forall (a = 1:3, b = 1:3)
                T_diff_num(a, b, 0) = diff5(T_diff_num(a, b, :), delta)
            end forall
            diff = T_diff_num(:, :, 0)-T_diff_anl(:, :, c)
            if (any(abs(diff) > 1d-12)) then
                call failed()
                call print_matrix('delta dTGG_{ab,' // trim(tostr(c)) // '}', diff)
                return
            end if
        end do
    end subroutine test_T_GG_deriv_expl

    subroutine test_T_GG_deriv_impl()
        real(8) :: r(3)
        type(dip33) :: T
        real(8) :: diff(3, 3)
        real(8) :: T_diff_anl(3, 3)
        real(8) :: T_diff_num(3, 3, -2:2)
        integer :: a, b, i_step
        real(8) :: delta
        real(8) :: sigma, dsigma_dr, sigma_diff

        delta = 1d-3
        r = [1.02d0, -2.22d0, 0.15d0]
        sigma = 1.2d0
        dsigma_dr = -0.3d0
        T = T_erf_coulomb(r, sigma, deriv=.true.)
        T_diff_anl = T%dsigma(:, :)*dsigma_dr
        do i_step = -2, 2
            if (i_step == 0) continue
            sigma_diff = sigma+i_step*delta*dsigma_dr
            T = T_erf_coulomb(r, sigma_diff, deriv=.false.)
            T_diff_num(:, :, i_step) = T%val
        end do
        forall (a = 1:3, b = 1:3)
            T_diff_num(a, b, 0) = diff5(T_diff_num(a, b, :), delta)
        end forall
        diff = T_diff_num(:, :, 0)-T_diff_anl
        if (any(abs(diff) > 1d-12)) then
            call failed()
            call print_matrix('delta dTGG', diff)
            return
        end if
    end subroutine test_T_GG_deriv_impl
end subroutine run_tests

end module mbd
