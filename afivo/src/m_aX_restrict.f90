! This module contains routines for restriction (going from fine to coarse
! variables).
!
! Author: Jannis Teunissen
! License: GPLv3

module m_a$D_restrict

  use m_a$D_t

  implicit none
  private

  public :: a$D_restrict_to_box
  public :: a$D_restrict_to_boxes
  public :: a$D_restrict_tree
  public :: a$D_restrict_box

contains

  !> Restrict the children of a box to the box (e.g., in 2D, average the values
  !> at the four children to get the value for the parent)
  subroutine a$D_restrict_to_box(boxes, id, iv, i_to)
    type(box$D_t), intent(inout)   :: boxes(:) !< List of all the boxes
    integer, intent(in)           :: id       !< Box whose children will be restricted to it
    integer, intent(in)           :: iv       !< Variable to restrict
    integer, intent(in), optional :: i_to    !< Destination (if /= iv)
    integer                       :: nc, i_c, c_id

    nc = boxes(id)%n_cell
    do i_c = 1, a$D_num_children
       c_id = boxes(id)%children(i_c)
       if (c_id == a5_no_box) cycle
       call a$D_restrict_box(boxes(c_id), boxes(id), iv, i_to)
    end do
  end subroutine a$D_restrict_to_box

  !> Restrict the children of boxes ids(:) to them.
  subroutine a$D_restrict_to_boxes(boxes, ids, iv, i_to)
    type(box$D_t), intent(inout)   :: boxes(:) !< List of all the boxes
    integer, intent(in)           :: ids(:)   !< Boxes whose children will be restricted to it
    integer, intent(in)           :: iv       !< Variable to restrict
    integer, intent(in), optional :: i_to    !< Destination (if /= iv)
    integer                       :: i

    !$omp parallel do
    do i = 1, size(ids)
       call a$D_restrict_to_box(boxes, ids(i), iv, i_to)
    end do
    !$omp end parallel do
  end subroutine a$D_restrict_to_boxes

  !> Restrict variables iv to all parent boxes, from the highest to the lowest level
  subroutine a$D_restrict_tree(tree, iv, i_to)
    type(a$D_t), intent(inout)     :: tree  !< Tree to restrict on
    integer, intent(in)           :: iv    !< Variable to restrict
    integer, intent(in), optional :: i_to !< Destination (if /= iv)
    integer                       :: lvl

    if (.not. tree%ready) stop "Tree not ready"
    do lvl = tree%max_lvl-1, lbound(tree%lvls, 1), -1
       call a$D_restrict_to_boxes(tree%boxes, tree%lvls(lvl)%parents, iv, i_to)
    end do
  end subroutine a$D_restrict_tree

  !> Restriction of child box (box_c) to its parent (box_p)
  subroutine a$D_restrict_box(box_c, box_p, iv, i_to)
#if $D == 2
    use m_a$D_utils, only: a$D_get_child_offset, a$D_cyl_radius_cc
#elif $D == 3
    use m_a$D_utils, only: a$D_get_child_offset
#endif
    type(box$D_t), intent(in)      :: box_c         !< Child box to restrict
    type(box$D_t), intent(inout)   :: box_p         !< Parent box to restrict to
    integer, intent(in)           :: iv            !< Variable to restrict
    integer, intent(in), optional :: i_to         !< Destination (if /= iv)
    integer                       :: i, j, i_f, j_f, i_c, j_c, i_dest
    integer                       :: hnc, ix_offset($D)
#if $D == 2
    real(dp)                      :: r, dr16, rfac
#elif $D == 3
    integer                       :: k, k_f, k_c
#endif

    hnc       = ishft(box_c%n_cell, -1) ! n_cell / 2
    ix_offset = a$D_get_child_offset(box_c)

    if (present(i_to)) then
       i_dest = i_to
    else
       i_dest = iv
    end if

#if $D == 2
    if (box_p%coord_t == a5_cyl) then
       dr16 = 0.0625_dp * box_p%dr   ! (dr / 4) / 4

       do j = 1, hnc
          j_c = ix_offset(2) + j
          j_f = 2 * j - 1
          do i = 1, hnc
             i_c = ix_offset(1) + i
             i_f = 2 * i - 1

             ! The weight of cells is proportional to their radius.
             r = a2_cyl_radius_cc(box_p, [i, j])
             rfac = dr16 / r

             box_p%cc(i_c, j_c, i_dest) = &
                  (0.25_dp - rfac) * sum(box_c%cc(i_f, j_f:j_f+1, iv)) + &
                  (0.25_dp + rfac) * sum(box_c%cc(i_f+1, j_f:j_f+1, iv))
          end do
       end do
    else
       do j = 1, hnc
          j_c = ix_offset(2) + j
          j_f = 2 * j - 1
          do i = 1, hnc
             i_c = ix_offset(1) + i
             i_f = 2 * i - 1
             box_p%cc(i_c, j_c, i_dest) = 0.25_dp * &
                  sum(box_c%cc(i_f:i_f+1, j_f:j_f+1, iv))
          end do
       end do
    endif
#elif $D == 3
    do k = 1, hnc
       k_c = ix_offset(3) + k
       k_f = 2 * k - 1
       do j = 1, hnc
          j_c = ix_offset(2) + j
          j_f = 2 * j - 1
          do i = 1, hnc
             i_c = ix_offset(1) + i
             i_f = 2 * i - 1
             box_p%cc(i_c, j_c, k_c, i_dest) = 0.125_dp * &
                  sum(box_c%cc(i_f:i_f+1, j_f:j_f+1, k_f:k_f+1, iv))
          end do
       end do
    end do
#endif
  end subroutine a$D_restrict_box

end module m_a$D_restrict
