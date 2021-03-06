!> \example test_reduction_2d.f90
!> This example shows the basic reduction functionality of m_a2_t.
program test_reduction
  use m_a2_t
  use m_a2_core
  use m_a2_utils

  implicit none

  type(a2_t)           :: tree
  integer              :: i
  integer, parameter   :: n_boxes_base = 1
  integer              :: ix_list(2, n_boxes_base)
  integer              :: nb_list(4, n_boxes_base)
  integer, parameter   :: box_size     = 8
  integer, parameter   :: i_phi        = 1
  integer, parameter   :: n_var_cell   = 1
  integer, parameter   :: n_var_face   = 0
  type(ref_info_t)     :: ref_info
  real(dp)             :: dr, max_val, min_val
  type(a2_loc_t)       :: max_loc, min_loc

  dr = 2 * acos(-1.0_dp) / box_size ! 2 * pi / box_size

  ! Initialize tree
  call a2_init(tree, & ! Tree to initialize
       box_size, &     ! Number of cells per coordinate in a box
       n_var_cell, &   ! Number of face-centered variables
       n_var_face, &   ! Number of cell-centered variables
       dr)             ! Distance between cells on base level

  ! Set up geometry
  ix_list(:, 1) = [1,1] ! One box at 1,1

  ! Periodic boundary conditions
  nb_list(:, 1) = 1

  ! Create the base mesh
  call a2_set_base(tree, ix_list, nb_list)

  ! Set variables on base
  call a2_loop_box(tree, set_random_values)

  do i = 1, 16
     print *, "i = ", i, "max_id", tree%max_id
     call a2_adjust_refinement(tree, set_ref_flags, ref_info)
     call a2_loop_box(tree, set_random_values)

     call a2_tree_max_cc(tree, i_phi, max_val)
     call a2_tree_min_cc(tree, i_phi, min_val)
     print *, "1 - max/min", max_val, min_val
     call a2_reduction(tree, box_max, max_ab, -huge(1.0_dp), max_val)
     call a2_reduction(tree, box_min, min_ab, huge(1.0_dp), min_val)
     print *, "2 - max/min", max_val, min_val
     call a2_reduction_loc(tree, box_max_ix, max_ab, -huge(1.0_dp), &
          max_val, max_loc)
     call a2_reduction_loc(tree, box_min_ix, min_ab, huge(1.0_dp), &
          min_val, min_loc)
     print *, "3 - max/min", max_val, min_val
     print *, "4 - max/min", tree%boxes(max_loc%id)%cc(max_loc%ix(1), &
          max_loc%ix(2), i_phi), tree%boxes(min_loc%id)%cc(min_loc%ix(1), &
          min_loc%ix(2), i_phi)
  end do

  call a2_destroy(tree)

contains

  real(dp) function box_max(box)
    type(box2_t), intent(in) :: box
    box_max = maxval(box%cc(1:box%n_cell, 1:box%n_cell, i_phi))
  end function box_max

  subroutine box_max_ix(box, val, ix)
    type(box2_t), intent(in) :: box
    real(dp), intent(out) :: val
    integer, intent(out) :: ix(2)
    ix = maxloc(box%cc(1:box%n_cell, 1:box%n_cell, i_phi))
    val = box%cc(ix(1), ix(2), i_phi)
  end subroutine box_max_ix

  subroutine box_min_ix(box, val, ix)
    type(box2_t), intent(in) :: box
    real(dp), intent(out) :: val
    integer, intent(out) :: ix(2)
    ix = minloc(box%cc(1:box%n_cell, 1:box%n_cell, i_phi))
    val = box%cc(ix(1), ix(2), i_phi)
  end subroutine box_min_ix

  real(dp) function box_min(box)
    type(box2_t), intent(in) :: box
    box_min = minval(box%cc(1:box%n_cell, 1:box%n_cell, i_phi))
  end function box_min

  real(dp) function max_ab(a,b)
    real(dp), intent(in) :: a, b
    max_ab = max(a,b)
  end function max_ab

  real(dp) function min_ab(a,b)
    real(dp), intent(in) :: a, b
    min_ab = min(a,b)
  end function min_ab

  subroutine set_ref_flags(boxes, id, ref_flags)
    type(box2_t), intent(in) :: boxes(:)
    integer, intent(in)      :: id
    integer, intent(inout)   :: ref_flags(:)
    real(dp)                 :: rr

    call random_number(rr)
    if (rr < 0.2_dp .and. boxes(id)%lvl < 10) then
       ref_flags(id) = a5_do_ref
    else
       ref_flags(id) = a5_rm_ref
    end if
  end subroutine set_ref_flags

  subroutine set_random_values(box)
    type(box2_t), intent(inout) :: box
    integer                     :: nc

    nc = box%n_cell
    call random_number(box%cc(1:nc, 1:nc, i_phi))
    box%cc(1:nc, 1:nc, i_phi) = 2 * box%cc(1:nc, 1:nc, i_phi) - 1
  end subroutine set_random_values

end program test_reduction
