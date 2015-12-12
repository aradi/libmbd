module mbd

! modes:
! M: multiprocessing (MPI)
! P: periodic
! R: reciprocal
! F: fourier
! Q: do RPA
! E: get eigenvalues
! V: get eigenvectors
! O: get RPA orders
! L: scale dipole with lambda


use mbd_interface, only: &
    sync_sum, broadcast, print_error, print_warning, print_log
use mbd_helper, only: &
    is_in, blanked


implicit none


real(8) :: &
    pi = acos(-1.d0), &
    nan = sqrt(-sin(0.d0))

real(8), parameter :: &
    bohr = 0.529177249d0

real(8) :: &
    param_scs_dip_cutoff = 120.d0/bohr, &
    param_mbd_supercell_cutoff = 25.d0/bohr, &
    param_mbd_dip_cutoff = 100.d0/bohr, &
    param_ts_energy_accuracy = 1.d-10, &
    param_dipole_matrix_accuracy = 1.d-10

integer :: &
    param_mbd_nbody_max = 3, &
    param_rpa_order_max = 10

logical :: &
    param_vacuum_axis(3) = (/ .false., .false., .false. /)

integer :: &
    n_grid_omega

real(8), allocatable :: &
    omega_grid(:), &
    omega_grid_w(:)

logical :: measure_time = .false.
integer(8) :: timestamps(100), ts_counts(100)
integer(8) :: ts_cnt, ts_rate, ts_cnt_max, ts_aid

character(len=1000) :: info_str

integer :: my_task, n_tasks


interface operator(.cprod.)
    module procedure cart_prod_
end interface

interface diag
    module procedure get_diag_
    module procedure make_diag_
end interface

interface diagonalize
    module procedure diagonalize_sym_dble_
    module procedure diagonalize_ge_dble_
    module procedure diagonalize_he_cmplx_
end interface

interface diagonalized
    module procedure diagonalized_sym_dble_
end interface

external :: ZHEEV, DGEEV, DSYEV, DGETRF, DGETRI, DGESV


contains


subroutine ts(id, always)
    implicit none

    integer, intent(in) :: id
    logical, intent(in), optional :: always

    if (measure_time .or. present(always)) then
        call system_clock(ts_cnt, ts_rate, ts_cnt_max) 
        if (id > 0) then
            timestamps(id) = timestamps(id)-ts_cnt
        else
            ts_aid = abs(id)
            timestamps(ts_aid) = timestamps(ts_aid)+ts_cnt
            ts_counts(ts_aid) = ts_counts(ts_aid)+1
        end if
    end if
end subroutine ts


function clock_rate() result(rate)
    implicit none

    integer(8) :: cnt, rate, cnt_max

    call system_clock(cnt, rate, cnt_max) 
end function clock_rate


function get_ts_energy( &
        mode, &
        version, &
        xyz, &
        C6, &
        alpha_0, &
        R_vdw, &
        s_R, &
        d, &
        overlap, &
        damping_custom, &
        unit_cell) &
        result(ene)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        C6(size(xyz, 1)), &
        alpha_0(size(xyz, 1))
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        s_R, d, &
        overlap(size(xyz, 1), size(xyz, 1)), &
        damping_custom(size(xyz, 1), size(xyz, 1)), &
        unit_cell(3, 3)
    real(8) :: ene

    real(8) :: C6_ij, r(3), r_norm, f_damp, R_vdw_ij, overlap_ij
    real(8) :: ene_shell, ene_pair
    real(8) :: r_cell(3)
    integer :: i_shell, i_cell
    integer :: i_atom, j_atom, range_g_cell(3), g_cell(3)
    real(8), parameter :: shell_thickness = 10.d0
    logical :: is_periodic, is_parallel

    is_periodic = is_in('P', mode)
    is_parallel = is_in('M', mode)

    ene = 0.d0
    i_shell = 0
    call ts(1)
    do
        i_shell = i_shell+1
        ene_shell = 0.d0
        call ts(10)
        if (is_periodic) then
            range_g_cell = supercell_circum(unit_cell, i_shell*shell_thickness)
        else
            range_g_cell = (/ 0, 0, 0 /)
        end if
        call ts(-10)
        g_cell = (/ 0, 0, -1 /)
        do i_cell = 1, product(1+2*range_g_cell)
            call ts(11)
            call shift_cell(g_cell, -range_g_cell, range_g_cell)
            call ts(-11)
            ! MPI code begin
            if (is_parallel .and. is_periodic) then
                if (my_task /= modulo(i_cell, n_tasks)) cycle
            end if
            ! MPI code end
            call ts(12)
            if (is_periodic) then
                r_cell = matmul(g_cell, unit_cell)
            else
                r_cell = (/ 0.d0, 0.d0, 0.d0 /)
            end if
            call ts(-12)
            do i_atom = 1, size(xyz, 1)
                ! MPI code begin
                if (is_parallel .and. .not. is_periodic) then
                    if (my_task /= modulo(i_atom, n_tasks)) cycle
                end if
                ! MPI code end
                do j_atom = 1, i_atom
                    if (i_cell == 1) then
                        if (i_atom == j_atom) cycle
                    end if
                    call ts(13)
                    r = xyz(i_atom, :)-xyz(j_atom, :)-r_cell
                    r_norm = sqrt(sum(r**2))
                    call ts(-13)
                    call ts(14)
                    if (r_norm >= i_shell*shell_thickness &
                        .or. r_norm < (i_shell-1)*shell_thickness) then
                        call ts(-14)
                        cycle
                    end if
                    call ts(-14)
                    call ts(15)
                    C6_ij = combine_C6( &
                        C6(i_atom), C6(j_atom), &
                        alpha_0(i_atom), alpha_0(j_atom))
                    call ts(-15)
                    call ts(16)
                    if (present(R_vdw)) then
                        R_vdw_ij = R_vdw(i_atom)+R_vdw(j_atom)
                    end if
                    call ts(-16)
                    if (present(overlap)) then
                        overlap_ij = overlap(i_atom, j_atom)
                    end if
                    call ts(2)
                    select case (version)
                        case ("fermi")
                            f_damp = damping_fermi(r_norm, s_R*R_vdw_ij, d)
                        case ("fermi2")
                            f_damp = damping_fermi(r_norm, s_R*R_vdw_ij, d)**2
                        case ("erf")
                            f_damp = damping_erf(r_norm, s_R*R_vdw_ij, d)
                        case ("1mexp")
                            f_damp = damping_1mexp(r_norm, s_R*R_vdw_ij, d)
                        case ("overlap")
                            f_damp = damping_overlap( &
                                r_norm, overlap_ij, C6_ij, s_R, d)
                        case ("custom")
                            f_damp = damping_custom(i_atom, j_atom)
                    end select
                    call ts(-2)
                    call ts(3)
                    ene_pair = -C6_ij*f_damp/r_norm**6
                    call ts(-3)
                    if (i_atom == j_atom) then
                        ene_shell = ene_shell+ene_pair/2
                    else
                        ene_shell = ene_shell+ene_pair
                    endif
                end do ! j_atom
            end do ! i_atom
        end do ! i_cell
        call ts(20)
        ! MPI code begin
        if (is_parallel) then
            call sync_sum(ene_shell)
        end if
        ! MPI code end
        call ts(-20)
        ene = ene+ene_shell
        if (.not. is_periodic) exit
        if (i_shell > 1 .and. abs(ene_shell) < param_ts_energy_accuracy) then
            write (info_str, "(a,i10,a,f10.0,a)") &
                "Periodic TS converged in ", &
                i_shell, &
                " shells, ", &
                i_shell*shell_thickness*bohr, &
                " angstroms"
            call print_log(info_str)
            exit
        endif
    end do ! i_shell
    call ts(-1)
end function get_ts_energy


subroutine add_dipole_matrix( &
        mode, &
        version, &
        xyz, &
        alpha, &
        R_vdw, &
        beta, &
        a, &
        overlap, &
        C6, &
        damping_custom, &
        potential_custom, &
        unit_cell, &
        k_point, &
        G_vector, &
        Gp_vector, &
        relay, &
        relay_c)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :)
    real(8), intent(in), optional :: &
        alpha(size(xyz, 1)), &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        overlap(size(xyz, 1), size(xyz, 1)), &
        C6(size(xyz, 1)), &
        damping_custom(size(xyz, 1), size(xyz, 1)), &
        potential_custom(size(xyz, 1), size(xyz, 1), 3, 3), &
        unit_cell(3, 3), &
        k_point(3), &
        G_vector(3), &
        Gp_vector(3)
    real(8), intent(inout), optional :: &
        relay(3*size(xyz, 1), 3*size(xyz, 1))
    complex(8), intent(inout), optional :: &
        relay_c(3*size(xyz, 1), 3*size(xyz, 1))

    real(8) :: Tpp(3, 3)
    complex(8) :: Tpp_c(3, 3)
    real(8) :: r_cell(3), r(3), r_norm
    real(8) :: R_vdw_ij, C6_ij, overlap_ij, sigma_ij
    real(8) :: max_change
    character(len=1) :: parallel_mode
    real(8), parameter :: shell_thickness = 50.d0
    integer :: &
        i_atom, j_atom, i_cell, g_cell(3), range_g_cell(3), i, j, &
        i_shell
    logical :: is_periodic, is_parallel, is_reciprocal, is_fourier

    is_parallel = is_in('M', mode)
    is_reciprocal = is_in('R', mode)
    is_fourier = is_in('F', mode)
    is_periodic = is_in('P', mode) .or. is_reciprocal .or. is_fourier
    if (is_parallel) then
        parallel_mode = 'A' ! atoms
        if (is_periodic .and. size(xyz, 1) < n_tasks) then
            parallel_mode = 'C' ! cells
        end if
    end if

    call ts(40)
    i_shell = 0
    do
        i_shell = i_shell+1
        max_change = 0.d0
        call ts(42)
        if (is_periodic) then
            range_g_cell = supercell_circum(unit_cell, i_shell*shell_thickness)
        else
            range_g_cell = (/ 0, 0, 0 /)
        end if
        call ts(-42)
        g_cell = (/ 0, 0, -1 /)
        do i_cell = 1, product(1+2*range_g_cell)
            call ts(43)
            call shift_cell(g_cell, -range_g_cell, range_g_cell)
            call ts(-43)
            ! MPI code begin
            if (parallel_mode == 'C') then
                if (my_task /= modulo(i_cell, n_tasks)) cycle
            end if
            ! MPI code end
            call ts(44)
            if (is_periodic) then
                r_cell = matmul(g_cell, unit_cell)
            else
                r_cell = (/ 0.d0, 0.d0, 0.d0 /)
            end if
            call ts(-44)
            do i_atom = 1, size(xyz, 1)
                ! MPI code begin
                if (parallel_mode == 'A') then
                    if (my_task /= modulo(i_atom, n_tasks)) cycle
                end if
                ! MPI code end
                do j_atom = 1, i_atom
                    if (i_cell == 1) then
                        if (i_atom == j_atom) cycle
                    end if
                    call ts(45)
                    r = xyz(i_atom, :)-xyz(j_atom, :)-r_cell
                    r_norm = sqrt(sum(r**2))
                    call ts(-45)
                    if (r_norm >= i_shell*shell_thickness &
                        .or. r_norm < (i_shell-1)*shell_thickness) cycle
                    call ts(46)
                    if (present(R_vdw)) then
                        R_vdw_ij = R_vdw(i_atom)+R_vdw(j_atom)
                    end if
                    if (present(alpha)) then
                        sigma_ij = sqrt(sum(get_sigma_selfint( &
                            alpha((/ i_atom , j_atom /)))**2))
                    end if
                    if (present(overlap)) then
                        overlap_ij = overlap(i_atom, j_atom)
                    end if
                    if (present(C6)) then
                        C6_ij = combine_C6( &
                            C6(i_atom), C6(j_atom), &
                            alpha(i_atom), alpha(j_atom))
                    end if
                    call ts(-46)
                    call ts(47)
                    select case (version)
                        case ("dip,1mexp")
                            Tpp = T_1mexp_coulomb(r, beta*R_vdw_ij, a)
                        case ("dip,erf")
                            Tpp = T_erf_coulomb(r, beta*R_vdw_ij, a)
                        case ("dip,fermi")
                            Tpp = T_fermi_coulomb(r, beta*R_vdw_ij, a)
                        case ("dip,overlap")
                            Tpp = T_overlap_coulomb(r, overlap_ij, C6_ij, beta, a)
                        case ("1mexp,dip")
                            Tpp = damping_1mexp(r_norm, beta*R_vdw_ij, a)*T_bare(r)
                        case ("erf,dip")
                            Tpp = damping_erf(r_norm, beta*R_vdw_ij, a)*T_bare(r)
                        case ("fermi,dip", "fermi@TS,dip", "fermi@rsSCS,dip")
                            Tpp = damping_fermi(r_norm, beta*R_vdw_ij, a)*T_bare(r)
                        case ("overlap,dip")
                            Tpp = damping_overlap( &
                                r_norm, overlap_ij, C6_ij, beta, a)*T_bare(r)
                        case ("custom,dip")
                            Tpp = damping_custom(i_atom, j_atom)*T_bare(r)
                        case ("dip,custom")
                            Tpp = potential_custom(i_atom, j_atom, :, :)
                        case ("dip,gg")
                            Tpp = T_erf_coulomb(r, sigma_ij, 1.d0)
                        case ("1mexp,dip,gg")
                            Tpp = (1.d0-damping_1mexp(r_norm, beta*R_vdw_ij, a)) &
                                *T_erf_coulomb(r, sigma_ij, 1.d0)
                        case ("erf,dip,gg")
                            Tpp = (1.d0-damping_erf(r_norm, beta*R_vdw_ij, a)) & 
                                *T_erf_coulomb(r, sigma_ij, 1.d0)
                        case ("fermi,dip,gg")
                            Tpp = (1.d0-damping_fermi(r_norm, beta*R_vdw_ij, a)) &
                                *T_erf_coulomb(r, sigma_ij, 1.d0)
                        case ("custom,dip,gg")
                            Tpp = (1.d0-damping_custom(i_atom, j_atom)) &
                                *T_erf_coulomb(r, sigma_ij, 1.d0)
                    end select
                    call ts(-47)
                    max_change = max(max_change, maxval(abs(Tpp)))
                    call ts(48)
                    if (is_reciprocal) then
                        Tpp_c = Tpp*exp(cmplx(0.d0, 1.d0, 8)*dot_product(k_point, r_cell))
                    end if
                    if (is_fourier) then
                        Tpp_c = Tpp*exp(-cmplx(0.d0, 1.d0, 8)*( &
                            dot_product(k_point, r) &
                            +dot_product(G_vector, xyz(i_atom, :)) &
                            -dot_product(Gp_vector, xyz(j_atom, :))))
                    end if
                    call ts(-48)
                    call ts(49)
                    i = 3*(i_atom-1)
                    j = 3*(j_atom-1)
                    if (is_reciprocal .or. is_fourier) then
                        relay_c(i+1:i+3, j+1:j+3) = relay_c(i+1:i+3, j+1:j+3) &
                            +Tpp_c
                        if (i_atom /= j_atom) then
                            relay_c(j+1:j+3, i+1:i+3) = relay_c(j+1:j+3, i+1:i+3) &
                                +transpose(Tpp_c)
                        end if
                    else
                        relay(i+1:i+3, j+1:j+3) = relay(i+1:i+3, j+1:j+3) &
                            +Tpp
                        if (i_atom /= j_atom) then
                            relay(j+1:j+3, i+1:i+3) = relay(j+1:j+3, i+1:i+3) &
                                +transpose(Tpp)
                        end if
                    end if
                    call ts(-49)
                end do ! j_atom
            end do ! i_atom
        end do ! i_cell
        if (.not. is_periodic) exit
        if (i_shell > 1 .and. max_change < param_dipole_matrix_accuracy) then
            write (info_str, "(a,i10,a,f10.0,a)") &
                "Periodic dipole matrix converged in ", &
                i_shell, &
                " shells, ", &
                i_shell*shell_thickness*bohr, &
                " angstroms"
            call print_log(info_str)
            exit
        endif
    end do ! i_shell
    call ts(41)
    ! MPI code begin
    if (is_parallel) then
        if (is_reciprocal .or. is_fourier) then
            call sync_sum(relay_c)
        else
            call sync_sum(relay)
        end if
    end if
    ! MPI code end
    call ts(-41)
    call ts(-40)
end subroutine add_dipole_matrix


function do_scs( &
        mode, &
        version, &
        xyz, &
        alpha, &
        R_vdw, &
        beta, &
        a, &
        lam, &
        unit_cell) & 
        result(alpha_full)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        alpha(:)
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        unit_cell(3, 3), &
        lam
    real(8) :: alpha_full(3*size(xyz, 1), 3*size(xyz, 1))
    logical :: scale_lambda

    integer :: i_atom, i_xyz, i

    scale_lambda = is_in('L', mode)

    alpha_full(:, :) = 0.d0
    call add_dipole_matrix( &
        mode, &
        version, &
        xyz=xyz, &
        alpha=alpha, &
        R_vdw=R_vdw, &
        beta=beta, &
        a=a, &
        unit_cell=unit_cell, &
        relay=alpha_full)
    if (scale_lambda) then
        alpha_full = lam*alpha_full
    end if
    do i_atom = 1, size(xyz, 1)
        do i_xyz = 1, 3
            i = 3*(i_atom-1)+i_xyz
            alpha_full(i, i) = alpha_full(i, i)+1.d0/alpha(i_atom)
        end do
    end do
    call invert(alpha_full)
end function do_scs


subroutine init_grid(n)
    implicit none

    integer, intent(in) :: n

    n_grid_omega = n
    allocate (omega_grid(0:n))
    allocate (omega_grid_w(0:n))
    omega_grid(0) = 0.d0
    omega_grid_w(0) = 0.d0
    call get_omega_grid(n, 10.d0, 2.d0, omega_grid(1:n), omega_grid_w(1:n))
end subroutine


subroutine destroy_grid()
    implicit none

    deallocate (omega_grid)
    deallocate (omega_grid_w)
end subroutine


function run_scs( &
        mode, &
        version, &
        xyz, &
        alpha, &
        R_vdw, &
        beta, &
        a, &
        unit_cell) & 
        result(alpha_scs)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        alpha(:, :)
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        unit_cell(3, 3)
    real(8) :: alpha_scs(size(alpha, 1), size(alpha, 2))

    real(8) :: alpha_full(3*size(xyz, 1), 3*size(xyz, 1))
    integer :: i_grid_omega
    logical :: is_parallel

    is_parallel = is_in('M', mode)

    alpha_scs(:, :) = 0.d0
    do i_grid_omega = 0, n_grid_omega
        ! MPI code begin
        if (is_parallel) then
            if (my_task /= modulo(i_grid_omega, n_tasks)) cycle
        end if
        ! MPI code end
        alpha_full = do_scs( &
            blanked('M', mode), &
            version, &
            xyz, &
            alpha=alpha(i_grid_omega+1, :), &
            R_vdw=R_vdw, &
            beta=beta, &
            a=a, &
            unit_cell=unit_cell)
        alpha_scs(i_grid_omega+1, :) = contract_polarizability(alpha_full)
    end do
    ! MPI code begin
    if (is_parallel) then
        call sync_sum(alpha_scs)
    end if
    ! MPI code end
end function run_scs


! function get_mbd_energy( &
!         mode, &
!         version, &
!         xyz, &
!         alpha_0, &
!         alpha, &
!         omega, &
!         C6, &
!         R_vdw, beta, a, &
!         overlap, &
!         damping_custom, &
!         potential_custom, &
!         unit_cell, &
!         k_point, &
!         k_grid, &
!         my_task, n_tasks, &
!         mode_enes, modes, &
!         rpa_orders) &
!         result(ene)
!     implicit none
!
!     character(len=*), intent(in) :: mode, version
!     real(8), intent(in) :: &
!         xyz(:, :)
!     real(8), intent(in), optional :: &
!         alpha_0(size(xyz, 1)), &
!         omega(size(xyz, 1)), &
!         R_vdw(size(xyz, 1)), &
!         beta, a, &
!         overlap(size(xyz, 1), size(xyz, 1)), &
!         C6(size(xyz, 1)), &
!         damping_custom(size(xyz, 1), size(xyz, 1)), &
!         potential_custom(size(xyz, 1), size(xyz, 1), 3, 3), &
!         unit_cell(3, 3), &
!         k_point(3)
!     integer, intent(in), optional :: my_task, n_tasks
!     real(8), intent(out), optional :: &
!         mode_enes(3*size(xyz, 1)), &
!         modes(3*size(xyz, 1), 3*size(xyz, 1))
!         rpa_orders(3*size(xyz, 1), 3*size(xyz, 1))
!     real(8) :: ene
!
!     real(8) :: relay(3*size(xyz, 1), 3*size(xyz, 1))
!     real(8) :: eigs(3*size(xyz, 1))
!     integer :: i_atom, j_atom, i_xyz, j_xyz, i, j
!     integer :: i_cell, j_cell, k_cell, i_cell_total, ijk_cell(3)
!     real(8) :: prefactor, Tpp(3, 3), R_vdw_sum, r(3), r_norm, C6_ij, overlap_ij
!     integer :: n_negative_eigs, g_cell(3), i_order
!     logical :: get_eigenvalues, get_eigenvectors
!
!     get_eigenvalues = is_in('E', mode)
!     get_eigenvectors = is_in('V', mode)
!
!     relay(:, :) = 0.d0
!     call add_dipole_matrix( & ! relay = T
!         mode, &
!         xyz, &
!         version, &
!         alpha_0, &
!         R_vdw, beta, a, &
!         overlap, &
!         C6, &
!         damping_custom, &
!         potential_custom, &
!         unit_cell, &
!         k_point, &
!         my_task, n_tasks, &
!         relay=relay)
!     do i_atom = 1, size(xyz, 1)
!         do j_atom = 1, size(xyz, 1)
!             i = 3*(i_atom-1)
!             j = 3*(j_atom-1)
!             relay(i+1:i+3, j+1:j+3) = & ! relay = -sqrt(a*a)*w*w*T
!                 -omega(i_atom)*omega(j_atom) &
!                 *sqrt(alpha_0(i_atom)*alpha_0(j_atom))* &
!                 relay(i+1:i+3, j+1:j+3)
!         end do
!     end do
!     do i_atom = 1, size(xyz, 1)
!         do i_xyz = 1, 3
!             i = 3*(i_atom-1)+i_xyz
!             relay(i, i) = relay(i, i)+omega(i_atom)**2
!             ! relay = w^2-sqrt(a*a)*w*w*T
!         end do
!     end do
!     if (get_eigenvectors) then
!         call diagonalize(relay, eigs, vectors=.true.)
!         modes = relay
!     else
!         call diagonalize(relay, eigs)
!     end if
!     if (get_eigenvalues) then
!         mode_enes(:) = 0.d0
!         where (eigs > 0) mode_enes = sqrt(eigs)
!     end if
!     n_negative_eigs = count(eigs(:) < 0)
!     if (n_negative_eigs > 0) then
!         write (info_str, "(a,i10,a)") &
!             "CDM Hamiltonian has ", n_negative_eigs, " negative eigenvalues"
!         call print_warning(info_str)
!     endif
!     where (eigs < 0) eigs = 0.d0
!     ene = 1.d0/2*sum(sqrt(eigs))-3.d0/2*sum(omega)
! end function get_mbd_energy


function get_single_mbd_energy( &
        mode, &
        version, &
        xyz, &
        alpha_0, &
        omega, &
        R_vdw, &
        beta, &
        a, &
        overlap, &
        C6, &
        damping_custom, &
        potential_custom, &
        unit_cell, &
        mode_enes, &
        modes) &
        result(ene)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        alpha_0(size(xyz, 1)), &
        omega(size(xyz, 1))
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        overlap(size(xyz, 1), size(xyz, 1)), &
        C6(size(xyz, 1)), &
        damping_custom(size(xyz, 1), size(xyz, 1)), &
        potential_custom(size(xyz, 1), size(xyz, 1), 3, 3), &
        unit_cell(3, 3)
    real(8), intent(out), optional :: &
        mode_enes(3*size(xyz, 1)), &
        modes(3*size(xyz, 1), 3*size(xyz, 1))
    real(8) :: ene

    real(8) :: relay(3*size(xyz, 1), 3*size(xyz, 1))
    real(8) :: eigs(3*size(xyz, 1))
    integer :: i_atom, j_atom, i_xyz, i, j
    integer :: n_negative_eigs
    logical :: get_eigenvalues, get_eigenvectors, is_parallel

    get_eigenvalues = is_in('E', mode)
    get_eigenvectors = is_in('V', mode)
    is_parallel = is_in('M', mode)

    call ts(10)
    relay(:, :) = 0.d0
    call add_dipole_matrix( & ! relay = T
        mode, &
        version, &
        xyz, &
        alpha=alpha_0, &
        R_vdw=R_vdw, &
        beta=beta, &
        a=a, &
        overlap=overlap, &
        C6=C6, &
        damping_custom=damping_custom, &
        potential_custom=potential_custom, &
        unit_cell=unit_cell, &
        relay=relay)
    call ts(-10)
    call ts(11)
    do i_atom = 1, size(xyz, 1)
        do j_atom = 1, size(xyz, 1)
            i = 3*(i_atom-1)
            j = 3*(j_atom-1)
            relay(i+1:i+3, j+1:j+3) = & ! relay = sqrt(a*a)*w*w*T
                omega(i_atom)*omega(j_atom) &
                *sqrt(alpha_0(i_atom)*alpha_0(j_atom))* &
                relay(i+1:i+3, j+1:j+3)
        end do
    end do
    call ts(-11)
    call ts(12)
    do i_atom = 1, size(xyz, 1)
        do i_xyz = 1, 3
            i = 3*(i_atom-1)+i_xyz
            relay(i, i) = relay(i, i)+omega(i_atom)**2
            ! relay = w^2+sqrt(a*a)*w*w*T
        end do
    end do
    call ts(-12)
    if (my_task == 0) then
        call ts(13)
        if (get_eigenvectors) then
            call diagonalize('V', relay, eigs)
            modes = relay
        else
            call diagonalize('N', relay, eigs)
        end if
        call ts(-13)
    end if
    ! MPI code begin
    if (is_parallel) then
        call broadcast(relay)
        call broadcast(eigs)
    end if
    ! MPI code end
    if (get_eigenvalues) then
        mode_enes(:) = 0.d0
        where (eigs > 0) mode_enes = sqrt(eigs)
    end if
    n_negative_eigs = count(eigs(:) < 0)
    if (n_negative_eigs > 0) then
        write (info_str, "(a,i10,a)") &
            "CDM Hamiltonian has ", n_negative_eigs, " negative eigenvalues"
        call print_warning(info_str)
        ene = nan
    else
        call ts(14)
        ene = 1.d0/2*sum(sqrt(eigs))-3.d0/2*sum(omega)
        call ts(-14)
    end if
end function get_single_mbd_energy


function get_single_reciprocal_mbd_energy( &
        mode, &
        version, &
        xyz, &
        alpha_0, &
        omega, &
        k_point, &
        unit_cell, &
        R_vdw, &
        beta, &
        a, &
        overlap, &
        C6, &
        damping_custom, &
        potential_custom, &
        mode_enes, &
        modes) &
        result(ene)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        alpha_0(size(xyz, 1)), &
        omega(size(xyz, 1)), &
        k_point(3), &
        unit_cell(3, 3)
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        overlap(size(xyz, 1), size(xyz, 1)), &
        C6(size(xyz, 1)), &
        damping_custom(size(xyz, 1), size(xyz, 1)), &
        potential_custom(size(xyz, 1), size(xyz, 1), 3, 3)
    real(8), intent(out), optional :: &
        mode_enes(3*size(xyz, 1))
    complex(8), intent(out), optional :: &
        modes(3*size(xyz, 1), 3*size(xyz, 1))
    real(8) :: ene

    complex(8) :: relay(3*size(xyz, 1), 3*size(xyz, 1))
    real(8) :: eigs(3*size(xyz, 1))
    integer :: i_atom, j_atom, i_xyz, i, j
    integer :: n_negative_eigs
    logical :: get_eigenvalues, get_eigenvectors

    get_eigenvalues = is_in('E', mode)
    get_eigenvectors = is_in('V', mode)

    call ts(10)
    relay(:, :) = cmplx(0.d0, 0.d0, 8)
    call add_dipole_matrix( & ! relay = T
        mode, &
        version, &
        xyz, &
        alpha=alpha_0, &
        R_vdw=R_vdw, &
        beta=beta, &
        a=a, &
        overlap=overlap, &
        C6=C6, &
        damping_custom=damping_custom, &
        potential_custom=potential_custom, &
        unit_cell=unit_cell, &
        k_point=k_point, &
        relay_c=relay)
    call ts(-10)
    call ts(11)
    do i_atom = 1, size(xyz, 1)
        do j_atom = 1, size(xyz, 1)
            i = 3*(i_atom-1)
            j = 3*(j_atom-1)
            relay(i+1:i+3, j+1:j+3) = & ! relay = sqrt(a*a)*w*w*T
                omega(i_atom)*omega(j_atom) &
                *sqrt(alpha_0(i_atom)*alpha_0(j_atom))* &
                relay(i+1:i+3, j+1:j+3)
        end do
    end do
    call ts(-11)
    call ts(12)
    do i_atom = 1, size(xyz, 1)
        do i_xyz = 1, 3
            i = 3*(i_atom-1)+i_xyz
            relay(i, i) = relay(i, i)+omega(i_atom)**2
            ! relay = w^2+sqrt(a*a)*w*w*T
        end do
    end do
    call ts(-12)
    call ts(13)
    if (get_eigenvectors) then
        call diagonalize('V', relay, eigs)
        modes = relay
    else
        call diagonalize('N', relay, eigs)
    end if
    call ts(-13)
    if (get_eigenvalues) then
        mode_enes(:) = 0.d0
        where (eigs > 0) mode_enes = sqrt(eigs)
    end if
    n_negative_eigs = count(eigs(:) < 0)
    if (n_negative_eigs > 0) then
        write (info_str, "(a,i10,a)") &
            "CDM Hamiltonian has ", n_negative_eigs, " negative eigenvalues"
        call print_warning(info_str)
    endif
    call ts(14)
    where (eigs < 0) eigs = 0.d0
    ene = 1.d0/2*sum(sqrt(eigs))-3.d0/2*sum(omega)
    call ts(-14)
end function get_single_reciprocal_mbd_energy


function get_reciprocal_mbd_energy( &
        mode, &
        version, &
        xyz, &
        alpha_0, &
        omega, &
        k_grid, &
        unit_cell, &
        R_vdw, &
        beta, &
        a, &
        overlap, &
        C6, &
        damping_custom, &
        potential_custom, &
        mode_enes, &
        modes, &
        rpa_orders) &
        result(ene)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        alpha_0(size(xyz, 1)), &
        omega(size(xyz, 1)), &
        k_grid(:, :), &
        unit_cell(3, 3)
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        overlap(size(xyz, 1), size(xyz, 1)), &
        C6(size(xyz, 1)), &
        damping_custom(size(xyz, 1), size(xyz, 1)), &
        potential_custom(size(xyz, 1), size(xyz, 1), 3, 3)
    real(8), intent(out), optional :: &
        rpa_orders(size(k_grid, 1), 20), &
        mode_enes(size(k_grid, 1), 3*size(xyz, 1))
    complex(8), intent(out), optional :: &
        modes(size(k_grid, 1), 3*size(xyz, 1), 3*size(xyz, 1))
    real(8) :: ene

    logical :: is_parallel, do_rpa, get_orders, get_eigenvalues, get_eigenvectors
    integer :: i_kpt
    real(8) :: k_point(3)

    is_parallel = is_in('M', mode)
    do_rpa = is_in('Q', mode)
    get_eigenvalues= is_in('E', mode)
    get_eigenvectors= is_in('V', mode)
    get_orders = is_in('O', mode)

    call ts(1)
    ene = 0.d0
    do i_kpt = 1, size(k_grid, 1)
        ! MPI code begin
        if (is_parallel) then
            if (my_task /= modulo(i_kpt, n_tasks)) cycle
        end if
        ! MPI code end
        k_point = k_grid(i_kpt, :)
        if (do_rpa) then
        else
            if (get_eigenvalues .and. get_eigenvectors) then
                ene = ene+get_single_reciprocal_mbd_energy( &
                    blanked('M', mode), &
                    version, &
                    xyz, &
                    alpha_0, &
                    omega, &
                    k_point, &
                    unit_cell, &
                    R_vdw=R_vdw, &
                    beta=beta, &
                    a=a, &
                    overlap=overlap, &
                    C6=C6, &
                    damping_custom=damping_custom, &
                    potential_custom=potential_custom, &
                    mode_enes=mode_enes(i_kpt, :), &
                    modes=modes(i_kpt, :, :))
            else
                ene = ene+get_single_reciprocal_mbd_energy( &
                    blanked('M', mode), &
                    version, &
                    xyz, &
                    alpha_0, &
                    omega, &
                    k_point, &
                    unit_cell, &
                    R_vdw=R_vdw, &
                    beta=beta, &
                    a=a, &
                    overlap=overlap, &
                    C6=C6, &
                    damping_custom=damping_custom, &
                    potential_custom=potential_custom)
            end if
        end if
    end do ! k_point loop
    call ts(2)
    ! MPI code begin
    if (is_parallel) then
        call sync_sum(ene)
        if (get_eigenvalues .and. get_eigenvectors) then
            call sync_sum(mode_enes)
            call sync_sum(modes)
        end if
        if (get_orders) then
            call sync_sum(rpa_orders)
        end if
    end if
    ! MPI code end
    call ts(-2)
    ene = ene/size(k_grid, 1)
    call ts(-1)
end function get_reciprocal_mbd_energy


function get_supercell_mbd_energy( &
        mode, &
        version, &
        xyz, &
        alpha_0, &
        omega, &
        unit_cell, &
        R_vdw, &
        beta, &
        a, &
        C6, &
        rpa_orders) &
        result(ene)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        alpha_0(size(xyz, 1)), &
        omega(size(xyz, 1)), &
        unit_cell(3, 3)
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        C6(size(xyz, 1))
    real(8), intent(out), optional :: rpa_orders(20)
    real(8) :: ene

    logical :: do_rpa
    real(8) :: r_cell(3)
    integer :: i_atom, i
    integer :: i_cell, range_g_cell(3)
    integer :: g_cell(3), n_cells

    real(8), allocatable :: &
        xyz_super(:, :), alpha_0_super(:), omega_super(:), &
        R_vdw_super(:), C6_super(:)
    real(8) :: unit_cell_super(3, 3)

    do_rpa = is_in('Q', mode)

    call ts(1)
    range_g_cell = supercell_circum(unit_cell, param_mbd_supercell_cutoff)
    write (info_str, "(a,i4,'x',i4,'x',i4,a)") &
        "Supercell MBD will be done in a ", &
        1+2*range_g_cell(1), 1+2*range_g_cell(2), 1+2*range_g_cell(3), &
        " supercell"
    call print_log(info_str)
    n_cells = product(1+2*range_g_cell)
    call ts(2)
    do i = 1, 3
        unit_cell_super(i, :) = unit_cell(i, :)*(1+2*range_g_cell(i))
    end do
    allocate (xyz_super(n_cells*size(xyz, 1), 3))
    allocate (alpha_0_super(n_cells*size(alpha_0)))
    allocate (omega_super(n_cells*size(omega)))
    allocate (R_vdw_super(n_cells*size(R_vdw)))
    allocate (C6_super(n_cells*size(C6)))
    g_cell = (/ 0, 0, -1 /)
    do i_cell = 1, n_cells
        call shift_cell(g_cell, -range_g_cell, range_g_cell)
        r_cell = matmul(g_cell, unit_cell)
        do i_atom = 1, size(xyz, 1)
            i = (i_cell-1)*size(xyz, 1)+i_atom
            xyz_super(i, :) = xyz(i_atom, :)+r_cell
            alpha_0_super(i) = alpha_0(i_atom)
            omega_super(i) = omega(i_atom)
            if (present(R_vdw)) then
                R_vdw_super(i) = R_vdw(i_atom)
            end if
            if (present(C6)) then
                C6_super(i) = C6(i_atom)
            end if
        end do
    end do
    call ts(-2)
    call ts(3)
    if (do_rpa) then
        ene = get_qho_rpa_energy( &
            mode, &
            version, &
            xyz_super, &
            alpha_dynamic_ts_all('O', n_grid_omega, alpha_0_super, omega=omega_super), &
            R_vdw=R_vdw_super, &
            beta=beta, &
            a=a, &
            C6=C6_super, &
            unit_cell=unit_cell_super, &
            rpa_orders=rpa_orders)
    else
        ene = get_single_mbd_energy( &
            mode, &
            version, &
            xyz_super, &
            alpha_0_super, &
            omega_super, &
            R_vdw=R_vdw_super, &
            beta=beta, &
            a=a, &
            C6=C6_super, &
            unit_cell=unit_cell_super)
    end if
    call ts(-3)
    deallocate (xyz_super)
    deallocate (alpha_0_super)
    deallocate (omega_super)
    deallocate (R_vdw_super)
    deallocate (C6_super)
    ene = ene/n_cells
    call ts(-1)
end function get_supercell_mbd_energy
    

! function mbd_nbody( &
!         xyz, &
!         alpha_0, &
!         omega, &
!         version, &
!         R_vdw, beta, a, &
!         my_task, n_tasks) &
!         result(ene_orders)
!     implicit none
!
!     real(8), intent(in) :: &
!         xyz(:, :), &
!         alpha_0(size(xyz, 1)), &
!         omega(size(xyz, 1)), &
!         R_vdw(size(xyz, 1)), &
!         beta, a
!     character(len=*), intent(in) :: version
!     integer, intent(in), optional :: my_task, n_tasks
!     real(8) :: ene_orders(20)
!
!     integer :: &
!         multi_index(param_mbd_nbody_max), i_body, j_body, i_tuple, &
!         i_atom_ind, j_atom_ind, i_index
!     real(8) :: ene
!     logical :: is_parallel
!     
!     is_parallel = .false.
!     if (present(n_tasks)) then
!         if (n_tasks > 0) then
!             is_parallel = .true.
!         end if
!     end if
!     ene_orders(:) = 0.d0
!     do i_body = 2, param_mbd_nbody_max
!         i_tuple = 0
!         multi_index(1:i_body-1) = 1
!         multi_index(i_body:param_mbd_nbody_max) = 0
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
!                 if (my_task /= modulo(i_tuple, n_tasks)) cycle
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
!     do i_body = 2, min(param_mbd_nbody_max, size(xyz, 1))
!         do j_body = 1, i_body-1
!             ene_orders(i_body) = ene_orders(i_body) &
!                 -nbody_coeffs(j_body, i_body, size(xyz, 1))*ene_orders(j_body)
!         end do
!     end do
!     ene_orders(1) = sum(ene_orders(2:param_mbd_nbody_max))
! end function mbd_nbody


function get_qho_rpa_energy( &
        mode, &
        version, &
        xyz, &
        alpha, &
        R_vdw, &
        beta, &
        a, &
        overlap, &
        C6, &
        damping_custom, &
        potential_custom, &
        unit_cell, &
        rpa_orders) &
        result(ene)
    implicit none

    character(len=*), intent(in) :: &
        mode, version
    real(8), intent(in) :: &
        xyz(:, :), &
        alpha(:, :)
    real(8), intent(in), optional :: &
        R_vdw(size(xyz, 1)), &
        beta, a, &
        overlap(size(xyz, 1), size(xyz, 1)), &
        C6(size(xyz, 1)), &
        damping_custom(size(xyz, 1), size(xyz, 1)), &
        potential_custom(size(xyz, 1), size(xyz, 1), 3, 3), &
        unit_cell(3, 3)
    real(8), intent(out), optional :: rpa_orders(20)
    real(8) :: ene

    real(8), dimension(3*size(xyz, 1), 3*size(xyz, 1)) :: relay, AT
    complex(8) :: eigs(3*size(xyz, 1))
    integer :: i_atom, i_xyz, i_grid_omega, i
    integer :: n_order, n_negative_eigs
    logical :: is_parallel, get_orders

    is_parallel = is_in('M', mode)
    get_orders = is_in('O', mode)

    do i_grid_omega = 0, n_grid_omega
        ! MPI code begin
        if (is_parallel) then
            if (my_task /= modulo(i_grid_omega, n_tasks)) cycle
        end if
        ! MPI code end
        relay(:, :) = 0.d0
        call add_dipole_matrix( & ! relay = T
            blanked('M', mode), &
            version, &
            xyz, &
            alpha=alpha(i_grid_omega+1, :), &
            R_vdw=R_vdw, &
            beta=beta, &
            a=a, &
            overlap=overlap, &
            C6=C6, &
            damping_custom=damping_custom, &
            potential_custom=potential_custom, &
            unit_cell=unit_cell, &
            relay=relay)
        do i_atom = 1, size(xyz, 1)
            do i_xyz = 1, 3
                i = (i_atom-1)*3+i_xyz
                relay(i, :) = alpha(i_grid_omega+1, i_atom)*relay(i, :) 
                ! relay = alpha*T
            end do
        end do
        AT = relay
        do i = 1, 3*size(xyz, 1)
            relay(i, i) = 1.d0+relay(i, i) ! relay = 1+alpha*T
        end do
        call diagonalize('N', relay, eigs)
        n_negative_eigs = count(dble(eigs) < 0)
        if (n_negative_eigs > 0) then
            write (info_str, "(a,i10,a)") &
                "1+AT matrix has ", n_negative_eigs, " negative eigenvalues"
            call print_warning(info_str)
        end if
        ene = ene+1.d0/(2*pi)*sum(log(dble(eigs)))*omega_grid_w(i_grid_omega)
        if (get_orders) then
            call diagonalize('N', AT, eigs)
            do n_order = 2, param_rpa_order_max
                rpa_orders(n_order) = rpa_orders(n_order) &
                    +(-1.d0/(2*pi)*(-1)**n_order*sum(dble(eigs)**n_order)/n_order) &
                    *omega_grid_w(i_grid_omega)
            end do
        end if
    end do
    if (is_parallel) then
        call sync_sum(ene)
        if (get_orders) then
            call sync_sum(rpa_orders)
        end if
    end if
end function get_qho_rpa_energy


function make_g_grid(n1, n2, n3) result(g_grid)
    integer, intent(in) :: n1, n2, n3
    real(8) :: g_grid(n1*n2*n3, 3)

    integer :: g_kpt(3), i_kpt, kpt_range(3), g_kpt_shifted(3)

    g_kpt = (/ 0, 0, -1 /)
    kpt_range = (/ n1, n2, n3 /)
    do i_kpt = 1, n1*n2*n3
        call shift_cell (g_kpt,(/ 0, 0, 0 /), kpt_range-1)
        g_kpt_shifted = g_kpt
        where (2*g_kpt > kpt_range) g_kpt_shifted = g_kpt-kpt_range
        g_grid(i_kpt, :) = real(g_kpt_shifted)/kpt_range
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
    implicit none

    real(8), intent(in) :: alpha_3n_3n(:, :)
    real(8) :: alpha_n(size(alpha_3n_3n, 1)/3)

    integer :: i_atom, i_xyz, j_xyz
    real(8) :: alpha_3_3(3, 3), alpha_diag(3)

    do i_atom = 1, size(alpha_n)
        forall (i_xyz = 1:3, j_xyz = 1:3) alpha_3_3(i_xyz, j_xyz) &
                = sum(alpha_3n_3n(i_xyz::3, 3*(i_atom-1)+j_xyz))
        alpha_diag = diagonalized(alpha_3_3)
        alpha_n(i_atom) = sum(alpha_diag)/3
    end do
end function contract_polarizability


subroutine get_omega_grid(n, a, m, x, w)
    implicit none

    integer, intent(in) :: n
    real(8), intent(in) :: a, m
    real(8), intent(out) :: x(n), w(n)

    integer :: i
    real(8) :: j(n), v(n)

    v = (/ (i, i = n, 1, -1) /)
    v = cos((2.d0*v-1.d0)/(2.d0*n)*pi)
    x = -a*log(1.d0-((1.d0+v)/2.d0)**m)
    j = a*m/((1.d0+v)*((2.d0/(1.d0+v))**m-1.d0))
    w = j*sqrt(1.d0-v**2)*pi/n
end subroutine get_omega_grid


function alpha_dynamic_ts_all(mode, n, alpha_0, C6, omega) result(alpha_dyn)
    implicit none

    character(len=1), intent(in) :: mode
    integer, intent(in) :: n
    real(8), intent(in) :: alpha_0(:)
    real(8), intent(in), optional :: C6(size(alpha_0)), omega(size(alpha_0))
    real(8) :: alpha_dyn(0:n, size(alpha_0))

    integer :: i_grid_omega

    do i_grid_omega = 0, n_grid_omega
        alpha_dyn(i_grid_omega, :) = alpha_dynamic_ts( &
            mode, alpha_0, omega_grid(i_grid_omega), C6, omega)
    end do
end function alpha_dynamic_ts_all


function alpha_dynamic_ts(mode, alpha_0, u, C6, omega) result(alpha)
    implicit none

    character(len=1), intent(in) :: mode
    real(8), intent(in) :: alpha_0(:), u
    real(8), intent(in), optional :: C6(size(alpha_0)), omega(size(alpha_0))
    real(8) :: alpha(size(alpha_0))

    select case (mode)
        case  ('O')
            alpha(:) = alpha_osc(alpha_0, omega, u)
        case ('C')
            alpha(:) = alpha_osc(alpha_0, omega_eff(C6, alpha_0), u)
    end select
end function


elemental function alpha_osc(alpha_0, omega, u) result(alpha)
    implicit none

    real(8), intent(in) :: alpha_0, omega, u
    real(8) :: alpha

    alpha = alpha_0/(1+(u/omega)**2)
end function


elemental function combine_C6 (C6_i, C6_j, alpha_0_i, alpha_0_j) result(C6_ij)
    implicit none

    real(8), intent(in) :: C6_i, C6_j, alpha_0_i, alpha_0_j
    real(8) :: C6_ij

    C6_ij = 2*C6_i*C6_j/(alpha_0_j/alpha_0_i*C6_i+alpha_0_i/alpha_0_j*C6_j)
end function


elemental function V_to_R(V) result(R)
    implicit none

    real(8), intent(in) :: V
    real(8) :: R

    R = (3.d0*V/(4.d0*pi))**(1.d0/3)
end function


elemental function vv_polarizability(rho, rho_grad, omega, C) result(alpha)
    implicit none

    real(8), intent(in) :: rho, rho_grad, omega, C
    real(8) :: alpha

    alpha = rho/(4*pi/3*rho+C*(rho_grad/rho)**4+omega**2)
end function


function omega_eff(C6, alpha) result(omega)
    implicit none

    real(8), intent(in) :: C6(:), alpha(size(C6))
    real(8) :: omega(size(C6))

    omega = 4.d0/3*C6/alpha**2
end function


elemental function get_sigma_selfint(alpha) result(sigma)
    implicit none

    real(8), intent(in) :: alpha
    real(8) :: sigma

    sigma = (sqrt(2.d0/pi)*alpha/3.d0)**(1.d0/3)
end function


function get_C6_from_alpha(alpha) result(C6)
    implicit none

    real(8), intent(in) :: alpha(:, :)
    real(8) :: C6(size(alpha, 2))
    integer :: i_atom

    do i_atom = 1, size(alpha, 2)
        C6(i_atom) = 3.d0/pi*sum((alpha(:, i_atom)**2)*omega_grid_w(:))
    end do
end function


function get_total_C6_from_alpha(alpha) result(C6)
    implicit none

    real(8), intent(in) :: alpha(:, :)
    real(8) :: C6

    C6 = 3.d0/pi*sum((sum(alpha, 2)**2)*omega_grid_w(:))
end function


function T_bare(rxyz) result(T)
    implicit none

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


function damping_fermi(r, sigma, a) result(f)
    implicit none

    real(8), intent(in) :: r, sigma, a
    real(8) :: f

    f = 1.d0/(1+exp(-a*(r/sigma-1)))
end function


function damping_erf(r, sigma, a) result(f)
    implicit none

    real(8), intent(in) :: r, sigma, a
    real(8) :: f

    f = erf((r/sigma)**a)
end function


function damping_1mexp(r, sigma, a) result(f)
    implicit none

    real(8), intent(in) :: r, sigma, a
    real(8) :: f

    f = 1-exp(-(r/sigma)**a)
end function


function damping_overlap(r, overlap, C6, beta, a) result(f)
    implicit none

    real(8), intent(in) :: r, overlap, C6, beta, a
    real(8) :: f

    f = 1.d0-terf(-overlap/(erf(r/6)**6*C6/r**6), beta, a)
end function


function T_overlap_coulomb(rxyz, overlap, C6, beta, a) result(T)
    implicit none

    real(8), intent(in) :: rxyz(3), overlap, C6, beta, a
    real(8) :: T(3, 3)

    real(8) :: zeta_1, zeta_2
    real(8) :: r, erff, exp36, qene, qenep, qenepp

    r = sqrt(sum(rxyz**2))
    erff = erf(r/6)
    exp36 = exp(r**2/36)
    qene = overlap*r**6/(C6*erff**6)
    qenep = 2.d0*overlap*r**5*(-(1.d0/exp36)*r/sqrt(pi)+3.d0*erff)/(C6*erff**7)
    qenepp = (1.d0/exp36**2)*overlap*r**4/(9*C6*pi*erff**8) &
        *(42*r**2+exp36*sqrt(pi)*r*(-216+r**2)*erff & 
        +270.d0*exp36**2*pi*erff**2)
    zeta_1 = 1.d0/2*(2.d0-erf(a*(beta-qene))+erf(a*(beta+qene)) &
        +2*a*r*qenep/sqrt(pi)*(-exp(-a**2*(beta-qene)**2) &
        -exp(-a**2*(beta+qene)**2)))
    zeta_2 = 1.d0/sqrt(pi)*a*exp(-a**2*(beta+qene)**2)*r**2 &
        *(2*a**2*qenep**2*(beta*(-1.d0+exp(4*a**2*beta*qene)) &
        -qene*(1.d0+exp(4*a**2*beta*qene))) &
        +qenepp*(1.d0+exp(4*a**2*beta*qene)))
    T = zeta_1*T_bare(rxyz)-zeta_2*(rxyz .cprod. rxyz)/sqrt(sum(rxyz**2))**5
end function


function T_fermi_coulomb(rxyz, sigma, a) result(T)
    implicit none

    real(8), intent(in) :: rxyz(3), sigma, a
    real(8) :: T(3, 3)

    real(8) :: r_sigma, d_r_sigma_m_1, zeta_1, zeta_2

    r_sigma = sqrt(sum(rxyz**2))/sigma
    d_r_sigma_m_1 = a*(r_sigma-1)
    zeta_1 = 1.d0/(1.d0+exp(-d_r_sigma_m_1)) &
        -a/2.d0*r_sigma/(1.d0+cosh(-d_r_sigma_m_1))
    zeta_2 = 2.d0*a**2*r_sigma**2/sinh(-d_r_sigma_m_1)**3 &
        *sinh(-d_r_sigma_m_1/2.d0)**4
    T = zeta_1*T_bare(rxyz)-zeta_2*(rxyz .cprod. rxyz)/sqrt(sum(rxyz**2))**5
end function


function T_erf_coulomb(rxyz, sigma, a) result(T)
    implicit none

    real(8), intent(in) :: rxyz(3), sigma, a
    real(8) :: T(3, 3)

    real(8) :: r_sigma, zeta_1, zeta_2

    r_sigma = (sqrt(sum(rxyz**2))/sigma)**a
    zeta_1 = erf(r_sigma)-2.d0/sqrt(pi)*a*r_sigma*exp(-r_sigma**2)
    zeta_2 = -2.d0/sqrt(pi)*a*r_sigma*exp(-r_sigma**2) &
        *(1.d0+a*(-1.d0+2.d0*r_sigma**2))
    T = zeta_1*T_bare(rxyz)-zeta_2*(rxyz .cprod. rxyz)/sqrt(sum(rxyz**2))**5
end function


function T_1mexp_coulomb(rxyz, sigma, a) result(T)
    implicit none

    real(8), intent(in) :: rxyz(3), sigma, a
    real(8) :: T(3, 3)

    real(8) :: r_sigma, zeta_1, zeta_2

    r_sigma = (sqrt(sum(rxyz**2))/sigma)**a
    zeta_1 = 1.d0-exp(-r_sigma)-a*r_sigma*exp(-r_sigma)
    zeta_2 = -r_sigma*a*exp(-r_sigma)*(1+a*(-1+r_sigma))
    T = zeta_1*T_bare(rxyz)-zeta_2*(rxyz .cprod. rxyz)/sqrt(sum(rxyz**2))**5
end function


subroutine get_damping_parameters( &
        xc, ts_d, ts_s_r, mbd_scs_a, mbd_ts_a, mbd_ts_erf_beta, &
        mbd_ts_fermi_beta, mbd_rsscs_a, mbd_rsscs_beta)
    implicit none

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


function solve_lin_sys(A, b) result(x)
    implicit none

    real(8), intent(in) :: A(:, :), b(size(A, 1))
    real(8) :: x(size(b))

    real(8) :: A_(size(b), size(b))
    integer :: i_pivot(size(b))
    integer :: n
    integer :: error_flag

    A_ = A
    x = b
    n = size(b)
    call DGESV(n, 1, A_, n, i_pivot, x, n, error_flag)
end function


function supercell_circum(uc, radius) result(sc)
    implicit none

    real(8), intent(in) :: uc(3, 3), radius
    integer :: sc(3)

    real(8) :: ruc(3, 3)

    ruc = 2*pi*inverted(transpose(uc))
    sc = ceiling(radius/sqrt(sum((uc*(diag(1.d0/sqrt(sum(ruc**2, 2)))*ruc))**2, 2))-0.5d0)
    where (param_vacuum_axis) sc = 0
end function


subroutine shift_cell(ijk, first_cell, last_cell)
    implicit none

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


function eye(n) result(A)
    implicit none

    integer, intent(in) :: n
    real(8) :: A(n, n)

    integer :: i

    A(:, :) = 0.d0
    forall (i = 1:n) A(i, i) = 1.d0
end function


elemental function terf(r, r0, a)
    implicit none

    real(8), intent(in) :: r, r0, a
    real(8) :: terf

    terf = 0.5d0*(erf(a*(r+r0))+erf(a*(r-r0)))
end function


subroutine invert(A)
    implicit none

    real(8), intent(inout) :: A(:, :)

    integer :: i_pivot(size(A, 1))
    real(8), allocatable :: work_arr(:)
    integer :: n
    integer :: n_work_arr
    real(8) :: n_work_arr_optim
    integer :: error_flag

    n = size(A, 1)
    call DGETRF(n, n, A, n, i_pivot, error_flag)
    if (error_flag /= 0) then
        write (info_str, "(a,i5)") &
            "Matrix inversion failed in module mbd with error code ", error_flag
        call print_error(info_str)
    endif
    call DGETRI(n, A, n, i_pivot, n_work_arr_optim, -1, error_flag)
    n_work_arr = nint(n_work_arr_optim)
    allocate (work_arr(n_work_arr))
    call DGETRI(n, A, n, i_pivot, work_arr, n_work_arr, error_flag)
    deallocate (work_arr)
    if (error_flag /= 0) then
        write (info_str, "(a,i5)") &
            "Matrix inversion failed in module mbd with error code ", error_flag
        call print_error(info_str)
    endif
end subroutine


function inverted(A) result(A_inv)
    implicit none

    real(8), intent(in) :: A(:, :)
    real(8) :: A_inv(size(A, 1), size(A, 2))

    A_inv = A
    call invert(A_inv)
end function


subroutine diagonalize_sym_dble_(mode, A, eigs)
    implicit none

    character(len=1), intent(in) :: mode
    real(8), intent(inout) :: A(:, :)
    real(8), intent(out) :: eigs(size(A, 1))

    real(8), allocatable :: work_arr(:)
    integer :: n
    real(8) :: n_work_arr
    integer :: error_flag

    n = size(A, 1)
    call DSYEV(mode, "U", n, A, n, eigs, n_work_arr, -1, error_flag)
    allocate (work_arr(nint(n_work_arr)))
    call DSYEV(mode, "U", n, A, n, eigs, work_arr, size(work_arr), error_flag)
    deallocate (work_arr)
    if (error_flag /= 0) then
        write (info_str, "(a,i5)") &
            "Matrix diagonalization failed in module mbd with error code", &
            error_flag
        call print_error(info_str)
    endif
end subroutine


function diagonalized_sym_dble_(A, eigvecs) result(eigs)
    implicit none

    real(8), intent(in) :: A(:, :)
    real(8), intent(out), optional, target :: eigvecs(size(A, 1), size(A, 2))
    real(8) :: eigs(size(A, 1))

    real(8), pointer :: eigvecs_p(:, :)
    character(len=1) :: mode

    if (present(eigvecs)) then
        mode = 'V'
        eigvecs_p => eigvecs
    else
        mode = 'N'
        allocate (eigvecs_p(size(A, 1), size(A, 2)))
    end if
    eigvecs_p = A
    call diagonalize(mode, eigvecs_p, eigs)
    if (.not. present(eigvecs)) then
        deallocate (eigvecs_p)
    end if
end function


subroutine diagonalize_ge_dble_(mode, A, eigs)
    implicit none

    character(len=1), intent(in) :: mode
    real(8), intent(inout) :: A(:, :)
    complex(8), intent(out) :: eigs(size(A, 1))

    real(8), allocatable :: work_arr(:)
    integer :: n
    real(8) :: n_work_arr
    integer :: error_flag
    real(8) :: eigs_r(size(A, 1)), eigs_i(size(A, 1))
    real(8) :: dummy
    real(8) :: vectors(size(A, 1), size(A, 2))

    n = size(A, 1)
    call DGEEV('N', mode, n, A, n, eigs_r, eigs_i, dummy, 1, &
        vectors, n, n_work_arr, -1, error_flag)
    allocate (work_arr(nint(n_work_arr)))
    call DGEEV('N', mode, n, A, n, eigs_r, eigs_i, dummy, 1, &
        vectors, n, work_arr, size(work_arr), error_flag)
    deallocate (work_arr)
    if (error_flag /= 0) then
        write (info_str, "(a,i5)") &
            "Matrix diagonalization failed in module mbd with error code", &
            error_flag
        call print_error(info_str)
    endif
    eigs = cmplx(eigs_r, eigs_i, 8)
    A = vectors
end subroutine


subroutine diagonalize_he_cmplx_(mode, A, eigs)
    implicit none

    character(len=1), intent(in) :: mode
    complex(8), intent(inout) :: A(:, :)
    real(8), intent(out) :: eigs(size(A, 1))

    complex(8), allocatable :: work(:)
    complex(8) :: lwork_cmplx
    real(8), allocatable :: rwork(:)
    integer :: n, lwork
    integer :: error_flag
    integer, external :: ILAENV

    n = size(A, 1)
    allocate (rwork(max(1, 3*n-2)))
    call ZHEEV(mode, "U", n, A, n, eigs, lwork_cmplx, -1, rwork, error_flag)
    lwork = nint(dble(lwork_cmplx))
    allocate (work(lwork))
    call ZHEEV(mode, "U", n, A, n, eigs, work, lwork, rwork, error_flag)
    deallocate (rwork)
    deallocate (work)
    if (error_flag /= 0) then
        write (info_str, "(a,i5)") &
            "Matrix diagonalization failed in module mbd with error code", &
            error_flag
        call print_error(info_str)
    endif
end subroutine


function cart_prod_(a, b) result(c)
    implicit none

    real(8), intent(in) :: a(:), b(:)
    real(8) :: c(size(a), size(b))

    integer :: i, j

    do i = 1, size(a)
        do j = 1, size(b)
            c(i, j) = a(i)*b(j)
        end do
    end do
end function


function get_diag_(A) result(d)
    implicit none

    real(8), intent(in) :: A(:, :)
    real(8) :: d(size(A, 1))

    integer :: i

    forall (i = 1:size(A, 1)) d(i) = A(i, i)
end function


function make_diag_(d) result(A)
    implicit none

    real(8), intent(in) :: d(:)
    real(8) :: A(size(d), size(d))

    integer :: i

    A(:, :) = 0.d0
    forall (i = 1:size(d)) A(i, i) = d(i)
end function


end module mbd
