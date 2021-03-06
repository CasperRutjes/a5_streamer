module m_photons
  use m_lookup_table

  implicit none
  private

  integer, parameter :: dp = kind(0.0d0)

  type PH_tbl_t
     type(LT_table_t) :: tbl           !< The lookup table
     real(dp)         :: frac_in_tbl   !< Fraction photons in table
  end type PH_tbl_t

  public :: PH_tbl_t

  ! Public methods
  public :: PH_get_tbl_air
  public :: PH_do_absorp
  public :: PH_absfunc_air
  public :: PH_set_src_2d
  public :: PH_set_src_3d

contains

  subroutine PH_get_tbl_air(phtbl, p_O2, max_dist)
    type(PH_tbl_t), intent(inout) :: phtbl      !< The photon table
    real(dp), intent(in)  :: p_O2     !< Partial pressure of oxygen (bar)
    real(dp), intent(in)  :: max_dist !< Maximum distance in lookup table

    integer               :: n
    integer, parameter    :: tbl_size  = 500
    real(dp), allocatable :: fsum(:), dist(:)
    real(dp)              :: dF, drdF, r, F, frac_guess


    ! First estimate which fraction of photons are within max_dist
    frac_guess = 1.0_dp

    ! 5 loops should be enough for a good guess
    do n = 1, 5
       dF = frac_guess / (tbl_size-1)
       r  = 0
       F  = 0

       do
          drdF = rk4_drdF(r, dF, p_O2)
          r = r + dF * drdF
          F = F + df

          if (r > max_dist) then
             frac_guess = F
             exit
          end if
       end do
    end do

    ! Make arrays larger so that we surely are in range of maxdist
    allocate(fsum(2 * tbl_size))
    allocate(dist(2 * tbl_size))

    ! Now create table
    dF = frac_guess / (tbl_size-1)
    dist(1) = 0
    fsum(1) = 0

    do n = 2, 2 * tbl_size
       drdF = rk4_drdF(dist(n-1), dF, p_O2)
       fsum(n) = fsum(n-1) + dF
       dist(n) = dist(n-1) + dF * drdF
       if (dist(n) > max_dist) exit
    end do

    if (n > tbl_size + 10) &
         stop "PH_get_tbl_air: integration accuracy fail"

    ! Scale table to lie between 0 and 1
    phtbl%frac_in_tbl = fsum(n-1)
    fsum(1:n-1) = fsum(1:n-1) / fsum(n-1)

    phtbl%tbl = LT_create(0.0_dp, 1.0_dp, tbl_size, 1)
    call LT_set_col(phtbl%tbl, 1, fsum(1:n-1), dist(1:n-1))
  end subroutine PH_get_tbl_air

  real(dp) function rk4_drdF(r, dF, p_O2)
    real(dp), intent(in)           :: r, dF, p_O2
    real(dp)                       :: drdF
    real(dp)                       :: sum_drdF
    real(dp), parameter            :: one_sixth = 1 / 6.0_dp

    ! Step 1 (at initial r)
    drdF = 1 / PH_absfunc_air(r, p_O2)
    sum_drdF = drdF

    ! Step 2 (at initial r + dr/2)
    drdF = 1 / PH_absfunc_air(r + 0.5_dp * dF * drdF, p_O2)
    sum_drdF = sum_drdF + 2 * drdF

    ! Step 3 (at initial r + dr/2)
    drdF = 1 / PH_absfunc_air(r + 0.5_dp * dF * drdF, p_O2)
    sum_drdF = sum_drdF + 2 * drdF

    ! Step 4 (at initial r + dr)
    drdF = 1 / PH_absfunc_air(r + dF * drdF, p_O2)
    sum_drdF = sum_drdF + drdF

    ! Combine r derivatives at steps
    rk4_drdF = one_sixth * sum_drdF
  end function rk4_drdF

  real(dp) function PH_absfunc_air(dist, p_O2)
    use m_units_constants
    real(dp), intent(in) :: dist, p_O2
    real(dp)             :: r
    real(dp), parameter  :: c0 = 3.5_dp / UC_torr_to_bar
    real(dp), parameter  :: c1 = 200 / UC_torr_to_bar
    real(dp), parameter  :: eps = epsilon(1.0_dp)

    r = p_O2 * dist
    if (r * (c0 + c1) < eps) then
       ! Use limit
       PH_absfunc_air = (c1 - c0 + 0.5_dp * (c0**2 - c1**2) * r) &
            * p_O2 / log(c1/c0)
    else if (r * c0 > -log(eps)) then
       PH_absfunc_air = eps
    else
       PH_absfunc_air = (exp(-c0 * r) - exp(-c1 * r)) / (dist * log(c1/c0))
    end if
  end function PH_absfunc_air

  integer function get_lvl_length(dr_base, length)
    real(dp), intent(in) :: dr_base, length
    real(dp), parameter :: invlog2 = 1 / log(2.0_dp)
    real(dp) :: ratio

    ratio = dr_base / length
    if (ratio <= 1) then
       get_lvl_length = 1
    else
       get_lvl_length = 1 + ceiling(log(ratio) * invlog2)
    end if
  end function get_lvl_length

  integer function get_rlvl_length(dr_base, length, rng)
    use m_random
    real(dp), intent(in) :: dr_base, length
    real(dp), parameter :: invlog2 = 1 / log(2.0_dp)
    type(RNG_t), intent(inout) :: rng
    real(dp) :: ratio, tmp

    ratio = dr_base / length
    if (ratio <= 1) then
       get_rlvl_length = 1
    else
       tmp = log(ratio) * invlog2
       get_rlvl_length = floor(tmp)
       if (rng%uni_01() < tmp - get_rlvl_length) &
            get_rlvl_length = get_rlvl_length + 1
    end if
  end function get_rlvl_length

  subroutine PH_do_absorp(xyz_in, xyz_out, n_dim, n_photons, tbl, rng)
    use m_lookup_table
    use m_random
    use omp_lib
    integer, intent(in)          :: n_photons
    real(dp), intent(in)         :: xyz_in(3, n_photons)
    real(dp), intent(out)        :: xyz_out(3, n_photons)
    integer, intent(in)          :: n_dim
    type(LT_table_t), intent(in) :: tbl
    type(RNG_t), intent(inout)   :: rng
    integer                      :: n, n_procs, proc_id
    real(dp)                     :: rr, dist
    type(PRNG_t)                 :: prng

    !$omp parallel private(n, rr, dist, proc_id)
    !$omp single
    n_procs = omp_get_num_threads()
    call prng%init(n_procs, rng)
    !$omp end single

    proc_id = 1+omp_get_thread_num()

    if (n_dim == 2) then
       !$omp do
       do n = 1, n_photons
          rr = prng%rngs(proc_id)%uni_01()
          dist = LT_get_col(tbl, 1, rr)
          xyz_out(1:n_dim, n) =  xyz_in(1:n_dim, n) + &
               prng%rngs(proc_id)%circle(dist)
       end do
       !$omp end do
    else if (n_dim == 3) then
       !$omp do
       do n = 1, n_photons
          rr = prng%rngs(proc_id)%uni_01()
          dist = LT_get_col(tbl, 1, rr)
          xyz_out(:, n) =  xyz_in(:, n) + prng%rngs(proc_id)%sphere(dist)
       end do
       !$omp end do
    else
       print *, "PH_do_absorp: unknown n_dim", n_dim
       stop
    end if
    !$omp end parallel
  end subroutine PH_do_absorp

  subroutine PH_set_src_2d(tree, pi_tbl, rng, num_photons, &
       i_src, i_pho, fac_dx, const_dx, use_cyl, min_dx, dt)
    use m_random
    use m_a2_t
    use m_a2_utils
    use m_a2_gc
    use m_a2_prolong
    use m_lookup_table
    use omp_lib

    type(a2_t), intent(inout)  :: tree   !< Tree
    type(PH_tbl_t)             :: pi_tbl !< Table to sample abs. lenghts
    type(RNG_t), intent(inout) :: rng    !< Random number generator
    !> How many discrete photons to use
    integer, intent(in)        :: num_photons
    !> Input variable that contains photon production per cell
    integer, intent(in)        :: i_src
    !> Output variable that contains photoionization source rate
    integer, intent(in)        :: i_pho
    !> Use dx proportional to this value
    real(dp), intent(in)       :: fac_dx
    !> Use constant grid spacing or variable
    logical, intent(in)        :: const_dx
    !> Use cylindrical coordinates
    logical, intent(in)        :: use_cyl
    !> Minimum spacing for absorption
    real(dp), intent(in)        :: min_dx
    !> Time step, if present use "physical" photons
    real(dp), intent(in), optional :: dt

    integer                     :: lvl, ix, id, nc, min_lvl, max_lvl
    integer                     :: i, j, n, n_create, n_used, i_ph
    integer                     :: proc_id, n_procs
    integer                     :: pho_lvl
    real(dp)                    :: tmp, dr, fac, dist, r(3)
    real(dp)                    :: sum_production, pi_lengthscale
    real(dp), allocatable       :: xyz_src(:, :)
    real(dp), allocatable       :: xyz_dst(:, :)
    real(dp), parameter         :: pi = acos(-1.0_dp)
    type(PRNG_t)                :: prng
    type(a2_loc_t), allocatable :: ph_loc(:)

    nc = tree%n_cell

    ! Compute the sum of photon production
    call a2_tree_sum_cc(tree, i_src, sum_production)

    if (present(dt)) then
       ! Create "physical" photons when less than num_photons are produced
       fac = min(dt, num_photons / (sum_production + epsilon(1.0_dp)))
    else
       ! Create approximately num_photons
       fac = num_photons / (sum_production + epsilon(1.0_dp))
    end if

    ! Allocate a bit more space because of stochastic production
    allocate(xyz_src(3, nint(1.2_dp * fac * sum_production + 1000)))

    ! Now loop over all leaves and create photons using random numbers
    n_used = 0

    !$omp parallel private(lvl, ix, id, i, j, n, r, dr, i_ph, proc_id, &
    !$omp tmp, n_create)

    !$omp single
    n_procs = omp_get_num_threads()
    call prng%init(n_procs, rng)
    !$omp end single

    proc_id = 1+omp_get_thread_num()

    do lvl = 1, tree%max_lvl
       dr = a2_lvl_dr(tree, lvl)
       !$omp do
       do ix = 1, size(tree%lvls(lvl)%leaves)
          id = tree%lvls(lvl)%leaves(ix)

          do j = 1, nc
             do i = 1, nc
                if (tree%boxes(id)%coord_t == a5_cyl) then
                   tmp = a2_cyl_radius_cc(tree%boxes(id), [i, j])
                   tmp = fac * 2 * pi * tmp * &
                        tree%boxes(id)%cc(i, j, i_src) * dr**2
                else
                   tmp = fac * tree%boxes(id)%cc(i, j, i_src) * dr**2
                end if

                n_create = floor(tmp)

                if (prng%rngs(proc_id)%uni_01() < tmp - n_create) &
                     n_create = n_create + 1

                if (n_create > 0) then
                   !$omp critical
                   i_ph = n_used
                   n_used = n_used + n_create
                   !$omp end critical

                   ! Location of production
                   r(1:2) = a2_r_cc(tree%boxes(id), [i, j])
                   r(3) = 0

                   do n = 1, n_create
                      xyz_src(:, i_ph+n) = r
                   end do
                end if
             end do
          end do
       end do
       !$omp end do nowait
    end do
    !$omp end parallel

    allocate(xyz_dst(3, n_used))
    allocate(ph_loc(n_used))


    if (use_cyl) then
       ! Get location of absorbption
       call PH_do_absorp(xyz_src, xyz_dst, 3, n_used, pi_tbl%tbl, rng)

       !$omp do
       do n = 1, n_used
          ! Set x coordinate to radius (norm of 1st and 3rd coord.)
          xyz_dst(1, n) = sqrt(xyz_dst(1, n)**2 + xyz_dst(3, n)**2)
       end do
       !$omp end do
    else
       ! Get location of absorbption
       call PH_do_absorp(xyz_src, xyz_dst, 2, n_used, pi_tbl%tbl, rng)
    end if

    if (const_dx) then
       ! Get a typical length scale for the absorption of photons
       pi_lengthscale = LT_get_col(pi_tbl%tbl, 1, fac_dx)

       ! Determine at which level we estimate the photoionization source term. This
       ! depends on the typical lenght scale for absorption.
       pho_lvl = get_lvl_length(tree%dr_base, pi_lengthscale)

       !$omp parallel do
       do n = 1, n_used
          ph_loc(n) = a2_get_loc(tree, xyz_dst(1:2, n), pho_lvl)
       end do
       !$omp end parallel do
    else
       max_lvl = get_lvl_length(tree%dr_base, min_dx)
       !$omp parallel private(n, dist, lvl, proc_id)
       proc_id = 1+omp_get_thread_num()
       !$omp do
       do n = 1, n_used
          dist = norm2(xyz_dst(1:2, n) - xyz_src(1:2, n))
          lvl = get_rlvl_length(tree%dr_base, fac_dx * dist, prng%rngs(proc_id))
          if (lvl > max_lvl) lvl = max_lvl
          ph_loc(n) = a2_get_loc(tree, xyz_dst(1:2, n), lvl)
       end do
       !$omp end do
       !$omp end parallel
    end if

    ! Clear variable i_pho, in which we will store the photoionization source term

    !$omp parallel private(lvl, i, id)
    do lvl = 1, tree%max_lvl
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call a2_box_clear_cc(tree%boxes(id), i_pho)
       end do
       !$omp end do nowait
    end do
    !$omp end parallel

    ! Add photons to production rate. Currently, this is done sequentially.
    if (use_cyl) then
       tmp = fac * 2 * pi       ! Temporary factor to speed up loop

       do n = 1, n_used
          id = ph_loc(n)%id
          if (id > a5_no_box) then
             i = ph_loc(n)%ix(1)
             j = ph_loc(n)%ix(2)
             dr = tree%boxes(id)%dr
             r(1:2) = a2_r_cc(tree%boxes(id), [i, j])
             tree%boxes(id)%cc(i, j, i_pho) = &
                  tree%boxes(id)%cc(i, j, i_pho) + &
                  pi_tbl%frac_in_tbl/(tmp * dr**2 * r(1))
          end if
       end do
    else
       do n = 1, n_used
          id = ph_loc(n)%id
          if (id > a5_no_box) then
             i = ph_loc(n)%ix(1)
             j = ph_loc(n)%ix(2)
             dr = tree%boxes(id)%dr
             tree%boxes(id)%cc(i, j, i_pho) = &
                  tree%boxes(id)%cc(i, j, i_pho) + &
                  pi_tbl%frac_in_tbl/(fac * dr**2)
          end if
       end do
    end if

    ! Set ghost cells on highest level with photon source
    if (const_dx) then
       min_lvl = pho_lvl
    else
       min_lvl = 1
    end if

    !$omp parallel private(lvl, i, id)
    ! Prolong to finer grids
    do lvl = min_lvl, tree%max_lvl-1
       !$omp do
       do i = 1, size(tree%lvls(lvl)%parents)
          id = tree%lvls(lvl)%parents(i)
          call a2_gc_box(tree%boxes, id, i_pho, &
               a2_gc_interp, a2_gc_neumann)
       end do
       !$omp end do

       !$omp do
       do i = 1, size(tree%lvls(lvl)%parents)
          id = tree%lvls(lvl)%parents(i)
          call a2_prolong1_from(tree%boxes, id, i_pho, add=.true.)
       end do
       !$omp end do
    end do
    !$omp end parallel
  end subroutine PH_set_src_2d

  subroutine PH_set_src_3d(tree, pi_tbl, rng, num_photons, &
       i_src, i_pho, fac_dx, const_dx, min_dx, dt)
    use m_random
    use m_a3_t
    use m_a3_utils
    use m_a3_gc
    use m_a3_prolong
    use m_lookup_table
    use omp_lib

    type(a3_t), intent(inout)   :: tree   !< Tree
    type(PH_tbl_t)              :: pi_tbl !< Table to sample abs. lenghts
    type(RNG_t), intent(inout)  :: rng    !< Random number generator
    !> How many discrete photons to use
    integer, intent(in)         :: num_photons
    !> Input variable that contains photon production per cell
    integer, intent(in)         :: i_src
    !> Output variable that contains photoionization source rate
    integer, intent(in)         :: i_pho
    !> Use dx proportional to this value
    real(dp), intent(in)        :: fac_dx
    !> Use constant grid spacing or variable
    logical, intent(in)         :: const_dx
    !> Minimum spacing for absorption
    real(dp), intent(in)        :: min_dx
    !> Time step, if present use "physical" photons
    real(dp), intent(in), optional :: dt

    integer                     :: lvl, ix, id, nc
    integer                     :: i, j, k, n, n_create, n_used, i_ph
    integer                     :: proc_id, n_procs
    integer                     :: pho_lvl, max_lvl, min_lvl
    real(dp)                    :: tmp, dr, fac, dist
    real(dp)                    :: sum_production, pi_lengthscale
    real(dp), allocatable       :: xyz_src(:, :)
    real(dp), allocatable       :: xyz_dst(:, :)
    type(PRNG_t)                :: prng
    type(a3_loc_t), allocatable :: ph_loc(:)

    nc = tree%n_cell

    ! Compute the sum of photon production
    call a3_tree_sum_cc(tree, i_src, sum_production)

    if (present(dt)) then
       ! Create "physical" photons when less than num_photons are produced
       fac = min(dt, num_photons / (sum_production + epsilon(1.0_dp)))
    else
       ! Create approximately num_photons
       fac = num_photons / (sum_production + epsilon(1.0_dp))
    end if

    ! Allocate a bit more space because of stochastic production
    allocate(xyz_src(3, nint(1.2_dp * fac * sum_production + 1000)))

    ! Now loop over all leaves and create photons using random numbers
    n_used = 0

    !$omp parallel private(lvl, ix, id, i, j, k, n, dr, i_ph, &
    !$omp proc_id, tmp, n_create)
    !$omp single
    n_procs = omp_get_num_threads()
    call prng%init(n_procs, rng)
    !$omp end single

    proc_id = 1+omp_get_thread_num()
    tmp = 0
    do lvl = 1, tree%max_lvl
       dr = a3_lvl_dr(tree, lvl)
       !$omp do
       do ix = 1, size(tree%lvls(lvl)%leaves)
          id = tree%lvls(lvl)%leaves(ix)

          do k = 1, nc
             do j = 1, nc
                do i = 1, nc
                   tmp = tmp + fac * tree%boxes(id)%cc(i, j, k, i_src) * dr**3
                   tmp = fac * tree%boxes(id)%cc(i, j, k, i_src) * dr**3
                   n_create = floor(tmp)

                   if (prng%rngs(proc_id)%uni_01() < tmp - n_create) &
                        n_create = n_create + 1

                   if (n_create > 0) then
                      !$omp critical
                      i_ph = n_used
                      n_used = n_used + n_create
                      !$omp end critical

                      do n = 1, n_create
                         xyz_src(:, i_ph+n) = &
                              a3_r_cc(tree%boxes(id), [i, j, k])
                      end do
                   end if
                end do
             end do
          end do
       end do
       !$omp end do nowait
    end do
    !$omp end parallel

    allocate(xyz_dst(3, n_used))
    allocate(ph_loc(n_used))

    ! Get location of absorbption
    call PH_do_absorp(xyz_src, xyz_dst, 3, n_used, pi_tbl%tbl, rng)

    if (const_dx) then
       ! Get a typical length scale for the absorption of photons
       pi_lengthscale = LT_get_col(pi_tbl%tbl, 1, fac_dx)

       ! Determine at which level we estimate the photoionization source term. This
       ! depends on the typical lenght scale for absorption.
       pho_lvl = get_lvl_length(tree%dr_base, pi_lengthscale)

       !$omp parallel do
       do n = 1, n_used
          ph_loc(n) = a3_get_loc(tree, xyz_dst(:, n), pho_lvl)
       end do
       !$omp end parallel do
    else
       max_lvl = get_lvl_length(tree%dr_base, min_dx)
       !$omp parallel private(n, dist, lvl, proc_id)
       proc_id = 1+omp_get_thread_num()
       !$omp do
       do n = 1, n_used
          dist = norm2(xyz_dst(:, n) - xyz_src(:, n))
          lvl = get_rlvl_length(tree%dr_base, fac_dx * dist, prng%rngs(proc_id))
          if (lvl > max_lvl) lvl = max_lvl
          ph_loc(n) = a3_get_loc(tree, xyz_dst(:, n), lvl)
       end do
       !$omp end do
       !$omp end parallel
    end if

    ! Clear variable i_pho, in which we will store the photoionization source term

    !$omp parallel private(lvl, i, id)
    do lvl = 1, tree%max_lvl
       !$omp do
       do i = 1, size(tree%lvls(lvl)%ids)
          id = tree%lvls(lvl)%ids(i)
          call a3_box_clear_cc(tree%boxes(id), i_pho)
       end do
       !$omp end do nowait
    end do
    !$omp end parallel

    ! Add photons to production rate. Currently, this is done sequentially.
    do n = 1, n_used
       id = ph_loc(n)%id
       if (id > a5_no_box) then
          i = ph_loc(n)%ix(1)
          j = ph_loc(n)%ix(2)
          k = ph_loc(n)%ix(3)
          dr = tree%boxes(id)%dr
          tree%boxes(id)%cc(i, j, k, i_pho) = &
               tree%boxes(id)%cc(i, j, k, i_pho) + &
               pi_tbl%frac_in_tbl/(fac * dr**3)
       end if
    end do

    ! Set ghost cells on highest level with photon source
    if (const_dx) then
       min_lvl = pho_lvl
    else
       min_lvl = 1
    end if

    !$omp parallel private(lvl, i, id)
    ! Prolong to finer grids
    do lvl = min_lvl, tree%max_lvl-1
       !$omp do
       do i = 1, size(tree%lvls(lvl)%parents)
          id = tree%lvls(lvl)%parents(i)
          call a3_gc_box(tree%boxes, id, i_pho, &
               a3_gc_interp, a3_gc_neumann)
       end do
       !$omp end do

       !$omp do
       do i = 1, size(tree%lvls(lvl)%parents)
          id = tree%lvls(lvl)%parents(i)
          call a3_prolong1_from(tree%boxes, id, i_pho, add=.true.)
       end do
       !$omp end do
    end do
    !$omp end parallel
  end subroutine PH_set_src_3d

end module m_photons
