!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!                                                                   !!
!!                   GNU General Public License                      !!
!!                                                                   !!
!! This file is part of the Flexible Modeling System (FMS).          !!
!!                                                                   !!
!! FMS is free software; you can redistribute it and/or modify       !!
!! it and are expected to follow the terms of the GNU General Public !!
!! License as published by the Free Software Foundation.             !!
!!                                                                   !!
!! FMS is distributed in the hope that it will be useful,            !!
!! but WITHOUT ANY WARRANTY; without even the implied warranty of    !!
!! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the     !!
!! GNU General Public License for more details.                      !!
!!                                                                   !!
!! You should have received a copy of the GNU General Public License !!
!! along with FMS; if not, write to:                                 !!
!!          Free Software Foundation, Inc.                           !!
!!          59 Temple Place, Suite 330                               !!
!!          Boston, MA  02111-1307  USA                              !!
!! or see:                                                           !!
!!          http://www.gnu.org/licenses/gpl.txt                      !!
!!                                                                   !!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
module ocean_pressure_mod
!  
! <CONTACT EMAIL="Stephen.Griffies@noaa.gov">
! S.M. Griffies 
! </CONTACT>
!
!<CONTACT EMAIL="Ronald.Pacanowski@noaa.gov"> R.C. Pacanowski
!</CONTACT>
!
! <REVIEWER EMAIL="Tony.Rosati@noaa.gov">
! A. Rosati 
! </REVIEWER>
!
!<OVERVIEW>
! Compute the hydrostatic pressure and forces from pressure. 
!</OVERVIEW>
!
!<DESCRIPTION>
! This module computes hydrostatic pressure and the pressure force
! acting at a velocity point (traditional finite difference approach).
! This force is used for the linear momentum equation.  
!
! This module takes account of the vertical coordinate,
! which determines details of the calculation.  
!</DESCRIPTION>
!
! <INFO>
!
! <REFERENCE>
! "Elements of mom4p1"
!  S.M. Griffies, (2007)
! </REFERENCE>
!
! </INFO>
!
!<NAMELIST NAME="ocean_pressure_nml">
!  <DATA NAME="debug_this_module" TYPE="logical">
!  For debugging. 
!  </DATA> 
!
!  <DATA NAME="zero_correction_term_grad" TYPE="logical">
!  For debugging it is often useful to zero the contribution to the 
!  pressure gradient that arises from the "correction" term. 
!  Implemented only for depth based vertical coordinate models.
!  </DATA> 
!  <DATA NAME="zero_diagonal_press_grad" TYPE="logical">
!  For debugging it is often useful to zero the contribution to the 
!  pressure gradient that arises from the along k-level gradient.
!  Implemented only for depth based vertical coordinate models.
!  </DATA> 
!  <DATA NAME="zero_pressure_force" TYPE="logical">
!  For debugging it is often useful to zero the pressure force
!  to zero.  
!  </DATA> 
!  <DATA NAME="zero_eta_over_h_zstar_pressure" TYPE="logical">
!  For debugging zstar, we drop any eta/H contribution to 
!  the hydrostatic pressure.  This is wrong physically, but 
!  useful for certain tests.   
!  </DATA> 
!
!</NAMELIST>

use constants_mod,    only: grav, c2dbars, epsln 
use diag_manager_mod, only: register_diag_field, send_data
use fms_mod,          only: open_namelist_file, check_nml_error, close_file, write_version_number
use mpp_io_mod,       only: mpp_open, mpp_close, MPP_RDONLY, MPP_ASCII
use mpp_mod,          only: mpp_error, FATAL, stdout, stdlog, mpp_chksum

use ocean_domains_mod,    only: get_local_indices
use ocean_operators_mod,  only: FAY, FAX, FDX_NT, FDY_ET 
use ocean_parameters_mod, only: GEOPOTENTIAL, ZSTAR, ZSIGMA
use ocean_parameters_mod, only: PRESSURE, PSTAR, PSIGMA
use ocean_parameters_mod, only: DEPTH_BASED, PRESSURE_BASED
use ocean_parameters_mod, only: ENERGETIC, FINITEVOLUME
use ocean_parameters_mod, only: missing_value, rho0, rho0r
use ocean_types_mod,      only: ocean_domain_type, ocean_grid_type
use ocean_types_mod,      only: ocean_time_type, ocean_velocity_type
use ocean_types_mod,      only: ocean_thickness_type, ocean_density_type
use ocean_util_mod,       only: write_timestamp
use ocean_workspace_mod,  only: wrk1, wrk2, wrk1_zw, wrk2_zw, wrk1_v, wrk2_v, wrk1_2d
use ocean_obc_mod,        only: store_ocean_obc_pressure_grad

implicit none

private

public ocean_pressure_init
public pressure_in_dbars
public pressure_force
public hydrostatic_pressure
public geopotential_anomaly 

private pressure_gradient_force_depth
private pressure_gradient_force_press

#include <ocean_memory.h>

type(ocean_domain_type), pointer :: Dom =>NULL()
type(ocean_grid_type), pointer   :: Grd =>NULL()

character(len=128) :: version = &
     '$Id: ocean_pressure.F90,v 16.0.108.1 2009/10/10 00:41:59 nnz Exp $'
character (len=128) :: tagname = &
     '$Name: mom4p1_pubrel_dec2009_nnz $'

! for vertical coordinate
integer :: vert_coordinate 
integer :: vert_coordinate_class

! useful constants
real :: grav_rho0r
real :: grav_rho0
real :: p5grav
real :: p5gravr
real :: p5grav_rho0r
real :: dbars2pa


! for computing geopotential at T-cell bottom from depth_zwt
real :: geopotential_switch=0.0

! for diagnostics
integer :: id_geopotential   =-1
integer :: id_anomgeopot     =-1
integer :: id_anomgeopot_zwt =-1
integer :: id_anompress      =-1
integer :: id_anompress_zwt  =-1

integer :: id_press_force(2)           =-1
integer :: id_pgrad_klev(2)            =-1
integer :: id_rhoprime_geograd_klev(2) =-1
integer :: id_rhoprime_pgrad_klev(2)   =-1
integer :: id_rho_geogradprime_klev(2) =-1

logical :: used

logical :: debug_this_module         =.false. 
logical :: zero_pressure_force       =.false.
logical :: zero_correction_term_grad =.false.
logical :: zero_diagonal_press_grad  =.false.
logical :: module_is_initialized     =.false.
logical :: have_obc                  =.false. 
logical :: zero_eta_over_h_zstar_pressure = .false. 

namelist /ocean_pressure_nml/ debug_this_module, zero_pressure_force, &
         zero_correction_term_grad, zero_diagonal_press_grad,         &
         zero_eta_over_h_zstar_pressure

contains

!#######################################################################
! <SUBROUTINE NAME="ocean_pressure_init">
!
! <DESCRIPTION>
! Initialize the pressure module
! </DESCRIPTION>
!
subroutine ocean_pressure_init(Grid, Domain, Time, ver_coordinate, &
                               ver_coordinate_class, obc, debug)

  type(ocean_grid_type),   target, intent(in) :: Grid
  type(ocean_domain_type), target, intent(in) :: Domain
  type(ocean_time_type),           intent(in) :: Time
  integer,                         intent(in) :: ver_coordinate
  integer,                         intent(in) :: ver_coordinate_class
  logical,                         intent(in) :: obc
  logical,               optional, intent(in) :: debug

  integer :: ioun, io_status, ierr

  integer :: stdoutunit,stdlogunit 
  stdoutunit=stdout();stdlogunit=stdlog() 

  if ( module_is_initialized ) then 
    call mpp_error( FATAL, &
    '==>Error: ocean_pressure_mod (ocean_pressure_init): module already initialized')
  endif 

  module_is_initialized = .TRUE.

  call write_version_number( version, tagname )

  have_obc              = obc
  vert_coordinate       = ver_coordinate
  vert_coordinate_class = ver_coordinate_class

  grav_rho0    = grav*rho0
  grav_rho0r   = grav*rho0r
  p5grav       = 0.5*grav
  p5gravr      = 0.5/grav
  p5grav_rho0r = 0.5*grav*rho0r 
  dbars2pa     = 1.0/c2dbars

  ioun = open_namelist_file()
  read  (ioun, ocean_pressure_nml,iostat=io_status)
  write (stdoutunit,'(/)')
  write (stdoutunit, ocean_pressure_nml)
  write (stdlogunit, ocean_pressure_nml)
  ierr = check_nml_error(io_status, 'ocean_pressure_nml')
  call close_file(ioun)

#ifndef MOM4_STATIC_ARRAYS
  call get_local_indices(Domain,isd, ied, jsd, jed, isc, iec, jsc, jec)
  nk = Grid%nk
#endif

  Dom => Domain
  Grd => Grid

  if (PRESENT(debug) .and. .not. debug_this_module) then
    debug_this_module = debug
  endif 
  if(debug_this_module) then 
    write(stdoutunit,'(a)') '==>Note: running ocean_pressure_mod with debug_this_module=.true.'  
  endif 

  if(zero_pressure_force) then 
    write(stdoutunit,*) &
    '==>Warning: Running mom4 with zero horizontal pressure force. Unrealistic simulation.'
  endif 

  if(vert_coordinate==GEOPOTENTIAL) then 
     geopotential_switch=0.0
  else
     geopotential_switch=1.0
  endif

  write(stdoutunit,*) &
       '==>NOTE: Running mom4p1 with finite difference formulation of pressure force.'

  if(zero_correction_term_grad) then 
      write(stdoutunit,*) &
           '==>Warning: Running mom4p1 with zero_correction_term_grad=.true. Unrealistic simulation.'
  endif

  if(zero_diagonal_press_grad) then 
      write(stdoutunit,*) &
           '==>Warning: Running mom4p1 with zero_diagonal_press_grad=.true. Unrealistic simulation.'
  endif


  ! register fields

  id_geopotential = register_diag_field ('ocean_model', 'geopotential', Grd%tracer_axes(1:3),&
   Time%model_time, 'geopotential at T-point', 'm^2/s^2',                                    &
   missing_value=missing_value, range=(/-1e8,1e8/))

  id_anompress = register_diag_field ('ocean_model', 'anompress', Grd%tracer_axes(1:3),&
   Time%model_time, 'anomalous hydrostatic pressure at T-point', 'Pa',                 &
   missing_value=missing_value, range=(/-1e8,1e8/))

  id_anompress_zwt = register_diag_field ('ocean_model', 'anompress_zwt', Grd%tracer_axes(1:3),&
   Time%model_time, 'anomalous hydrostatic pressure at T-cell bottom', 'Pa',                   &
   missing_value=missing_value, range=(/-1e8,1e8/))

  id_anomgeopot = register_diag_field ('ocean_model', 'anomgeopot', Grd%tracer_axes(1:3),&
   Time%model_time, 'anomalous geopotential at T-point', 'm^2/s^2',                      &
   missing_value=missing_value, range=(/-1e8,1e8/))

  id_anomgeopot_zwt = register_diag_field ('ocean_model', 'anomgeopot_zwt', Grd%tracer_axes(1:3),&
   Time%model_time, 'anomalous geopotential at T-cell bottom', 'm^2/s^2',                        &
   missing_value=missing_value, range=(/-1e8,1e8/))

  id_pgrad_klev(1) = register_diag_field ('ocean_model', 'dzupgrad_x_klev', Grd%vel_axes_uv(1:3), &
     Time%model_time, 'dzu*dp_dx on k-level', 'Pa', missing_value=missing_value, range=(/-1e9,1e9/))
  id_pgrad_klev(2) = register_diag_field ('ocean_model', 'dzupgrad_y_klev', Grd%vel_axes_uv(1:3), &
     Time%model_time, 'dzu*dp_dy on k-level', 'Pa', missing_value=missing_value, range=(/-1e9,1e9/))

  id_rhoprime_geograd_klev(1) = register_diag_field ('ocean_model', 'dzurhoprime_geograd_x_klev', &
     Grd%vel_axes_uv(1:3), Time%model_time, 'dzu*rhoprime*d(geopot)/dx on k-level', 'Pa',         &
     missing_value=missing_value, range=(/-1e9,1e9/))
  id_rhoprime_geograd_klev(2) = register_diag_field ('ocean_model', 'dzurhoprime_geograd_y_klev', &
    Grd%vel_axes_uv(1:3), Time%model_time, 'dzu*rhoprime*d(geopot)/dx on k-level', 'Pa',          &
    missing_value=missing_value, range=(/-1e9,1e9/))

  id_rhoprime_pgrad_klev(1) = register_diag_field ('ocean_model', 'dzurhoprime_pgrad_x_klev', &
     Grd%vel_axes_uv(1:3), Time%model_time, 'dzu*(rhoprime/rho0)*dp/dx on k-level', 'Pa',     &
     missing_value=missing_value, range=(/-1e9,1e9/))
  id_rhoprime_pgrad_klev(2) = register_diag_field ('ocean_model', 'dzurhoprime_pgrad_y_klev', &
     Grd%vel_axes_uv(1:3), Time%model_time, 'dzu*(rhoprime/rho0)*dp/dy on k-level', 'Pa',     &
     missing_value=missing_value, range=(/-1e9,1e9/))

  id_rho_geogradprime_klev(1) = register_diag_field ('ocean_model', 'dzurho_geogradprime_x_klev',&
    Grd%vel_axes_uv(1:3), Time%model_time, 'dzu*rho*d(geopot_prime)/dx on k-level', 'Pa',        &
    missing_value=missing_value, range=(/-1e9,1e9/))
  id_rho_geogradprime_klev(2) = register_diag_field ('ocean_model', 'dzurho_geogradprime_y_klev',&
    Grd%vel_axes_uv(1:3), Time%model_time, 'dzu*rho*d(geopot_prime)/dy on k-level', 'Pa/m',      &
    missing_value=missing_value, range=(/-1e9,1e9/))

  id_press_force(1) = register_diag_field ('ocean_model', 'press_force_u',  &
     Grd%vel_axes_uv(1:3), Time%model_time, 'i-directed pressure force',    &
     'Pa', missing_value=missing_value, range=(/-1e9,1e9/))
  id_press_force(2) = register_diag_field ('ocean_model', 'press_force_v', &
     Grd%vel_axes_uv(1:3), Time%model_time, 'j-directed pressure force',   &
     'Pa', missing_value=missing_value, range=(/-1e9,1e9/))
 

end subroutine ocean_pressure_init
! </SUBROUTINE> NAME="ocean_pressure_init"


!#######################################################################
! <SUBROUTINE NAME="pressure_force">
!
! <DESCRIPTION>
! Compute the horizontal force [Pa=N/m^2] from pressure. 
!
! Use the traditional approach whereby the pressure force
! is computed as a finite difference gradient centred 
! at the U-cell point. 
!
! </DESCRIPTION>
!
subroutine pressure_force(Time, Thickness, Dens, Velocity, rho)

  type(ocean_time_type),          intent(in)    :: Time
  type(ocean_thickness_type),     intent(in)    :: Thickness
  type(ocean_density_type),       intent(in)    :: Dens
  type(ocean_velocity_type),      intent(inout) :: Velocity
  real, dimension(isd:,jsd:,:),   intent(in)    :: rho

  integer :: tau 
 
  integer :: stdoutunit 
  stdoutunit=stdout() 

  tau = Time%tau 

  if ( .not. module_is_initialized ) then 
    call mpp_error(FATAL, &
    '==>Error in ocean_pressure_mod (pressure_force): module must be initialized')
  endif 

  if(vert_coordinate_class==DEPTH_BASED) then 
      call pressure_gradient_force_depth(Time, Thickness, Velocity, rho)
  else 
      call pressure_gradient_force_press(Time, Thickness, Dens, Velocity, rho)
  endif

  ! for debugging 
  if(zero_pressure_force) then 
      Velocity%press_force = 0.0
  endif

  ! for open boundaries 
  if (have_obc) call store_ocean_obc_pressure_grad(Thickness, Velocity%press_force, tau) 

  ! send some diagnostics 

  if(id_geopotential > 0) used = send_data( id_geopotential, -grav*Thickness%geodepth_zt(:,:,:), &
       Time%model_time, rmask=Grd%tmask(:,:,:),                                                  &
       is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)

  if (id_press_force(1) > 0) then 
       used = send_data( id_press_force(1), Velocity%press_force(:,:,:,1), &
       Time%model_time, rmask=Grd%umask(:,:,:),                            &
       is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif 
  if (id_press_force(2) > 0) then 
       used = send_data( id_press_force(2), Velocity%press_force(:,:,:,2), &
       Time%model_time, rmask=Grd%umask(:,:,:),                            &
       is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif 

  ! more debugging 
  if(debug_this_module) then 
      write(stdoutunit,*)' '
      write(stdoutunit,*) 'From ocean_pressure_mod: pressure chksums'
      call write_timestamp(Time%model_time)
      write(stdoutunit,*) 'rho_dzu(tau)   = ', &
       mpp_chksum(Thickness%rho_dzu(isc:iec,jsc:jec,:,tau)*Grd%umask(isc:iec,jsc:jec,:))
      write(stdoutunit,*) 'press_force(1) = ', &
       mpp_chksum(Velocity%press_force(isc:iec,jsc:jec,:,1)*Grd%umask(isc:iec,jsc:jec,:))
      write(stdoutunit,*) 'press_force(2) = ', &
       mpp_chksum(Velocity%press_force(isc:iec,jsc:jec,:,2)*Grd%umask(isc:iec,jsc:jec,:))
  endif 


end subroutine pressure_force
! </SUBROUTINE> NAME="pressure_force"



!#######################################################################
! <SUBROUTINE NAME="pressure_gradient_force_depth">
!
! <DESCRIPTION>
! Compute the force from pressure using a finite difference method
! to compute the thickness weighted pressure gradient at the 
! velocity cell point. 
!
! For depth-like vertical coordinates, we exclude surface and applied 
! pressures (i.e., we are computing here the gradient of the baroclinic 
! pressure).  Account is taken of variable partial cell thickness.
! 1 = dp/dx; 2 = dp/dy
!
! Thickness weight since this is what we wish to use in update of 
! the velocity. Resulting thickness weighted pressure gradient has 
! dimensions of Pa = N/m^2 = kg/(m*s^2).
!
! Thickness%dzu should be at tau.
!
! </DESCRIPTION>
!
subroutine pressure_gradient_force_depth(Time, Thickness, Velocity, rho)

  type(ocean_time_type),          intent(in)    :: Time
  type(ocean_thickness_type),     intent(in)    :: Thickness
  type(ocean_velocity_type),      intent(inout) :: Velocity
  real, dimension(isd:,jsd:,:),   intent(in)    :: rho

  real, dimension(isd:ied,jsd:jed) :: diff_geo_x
  real, dimension(isd:ied,jsd:jed) :: diff_geo_y
  real, dimension(isd:ied,jsd:jed) :: tmp1
  real, dimension(isd:ied,jsd:jed) :: tmp2
  integer :: i, j, k
  integer :: tau

  if ( .not. module_is_initialized ) then 
    call mpp_error(FATAL, &
    '==>Error in ocean_pressure_mod (pressure_gradient_force_depth): module must be initialized')
  endif 

  tau    = Time%tau
  tmp1   = 0.0
  tmp2   = 0.0
  wrk1_v = 0.0
  wrk2_v = 0.0


  ! use density anomaly to improve accuracy 
  do k=1,nk
     do j=jsd,jed
        do i=isd,ied
           wrk2(i,j,k) = Grd%tmask(i,j,k)*(rho(i,j,k)-rho0)
        enddo
     enddo
  enddo
  
  ! compute hydrostatic pressure anomaly at T-point 
  ! ( Pa=N/m^2=kg/(m*s^2) )
  wrk1(:,:,:) = hydrostatic_pressure(Thickness, wrk2(:,:,:))  

  if(id_anompress > 0) then 
      used = send_data( id_anompress, wrk1(:,:,:),  &
           Time%model_time, rmask=Grd%tmask(:,:,:), &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif

  diff_geo_x(:,:) = 0.0
  diff_geo_y(:,:) = 0.0

  do k=1,nk

     do j=jsd,jed
        do i=isd,iec
           diff_geo_x(i,j) = -grav*(Thickness%geodepth_zt(i+1,j,k)-Thickness%geodepth_zt(i,j,k))
        enddo
     enddo
     do j=jsd,jec
        do i=isd,ied
           diff_geo_y(i,j) = -grav*(Thickness%geodepth_zt(i,j+1,k)-Thickness%geodepth_zt(i,j,k))
        enddo
     enddo

     ! density anomaly times geopotential gradient on k-levels 
     ! (dzurhoprime_geograd_x_klev,dzurhoprime_geograd_y_klev)
     tmp1(:,:) = FAY(FAX(wrk2(:,:,k))*diff_geo_x(:,:))
     tmp2(:,:) = FAX(FAY(wrk2(:,:,k))*diff_geo_y(:,:))
     do j=jsc,jec
        do i=isc,iec
           wrk1_v(i,j,k,1) = tmp1(i,j)*Grd%dxur(i,j)*Thickness%dzu(i,j,k)
           wrk1_v(i,j,k,2) = tmp2(i,j)*Grd%dyur(i,j)*Thickness%dzu(i,j,k)
        enddo
     enddo
     if(zero_correction_term_grad) then 
         wrk1_v(:,:,:,:) = 0.0
     endif

     ! gradient of anomalous baroclinic pressure on k-levels 
     ! (dzupgrad_x_klev,dzupgrad_y_klev)
     tmp1(:,:) = FDX_NT(FAY(wrk1(:,:,k)))
     tmp2(:,:) = FDY_ET(FAX(wrk1(:,:,k)))
     do j=jsc,jec
        do i=isc,iec
           wrk2_v(i,j,k,1) = tmp1(i,j)*Thickness%dzu(i,j,k)
           wrk2_v(i,j,k,2) = tmp2(i,j)*Thickness%dzu(i,j,k)
        enddo
     enddo

     if(zero_diagonal_press_grad) then 
         wrk2_v(:,:,:,:) = 0.0
     endif

     ! thickness weighted baroclinic pressure gradient on z-levels
     ! (dzu_pgrad_u,dzu_pgrad_v)
     do j=jsc,jec
        do i=isc,iec    
           Velocity%press_force(i,j,k,1) = -Grd%umask(i,j,k)*( wrk1_v(i,j,k,1) + wrk2_v(i,j,k,1) )
           Velocity%press_force(i,j,k,2) = -Grd%umask(i,j,k)*( wrk1_v(i,j,k,2) + wrk2_v(i,j,k,2) )
        enddo
     enddo

  enddo   ! k do-loop finish 


  ! (dzurhoprime_geograd_x_klev,dzurhoprime_geograd_y_klev)
  if (id_rhoprime_geograd_klev(1) > 0) then 
      used=send_data( id_rhoprime_geograd_klev(1),wrk1_v(:,:,:,1), &
           Time%model_time, rmask=Grd%umask(:,:,:),                &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif
  if (id_rhoprime_geograd_klev(2) > 0) then 
      used=send_data( id_rhoprime_geograd_klev(2),wrk1_v(:,:,:,2), &
           Time%model_time, rmask=Grd%umask(:,:,:),                &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif

  ! (dzupgrad_x_klev,dzupgrad_y_klev)
  if (id_pgrad_klev(1) > 0) then 
      used = send_data( id_pgrad_klev(1), wrk2_v(:,:,:,1), &
           Time%model_time, rmask=Grd%umask(:,:,:),        &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif
  if (id_pgrad_klev(2) > 0) then 
      used = send_data( id_pgrad_klev(2), wrk2_v(:,:,:,2), &
           Time%model_time, rmask=Grd%umask(:,:,:),        &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif


end subroutine pressure_gradient_force_depth
! </SUBROUTINE> NAME="pressure_gradient_force_depth"



!#######################################################################
! <SUBROUTINE NAME="pressure_gradient_force_press">
!
! <DESCRIPTION>
! Compute the force from pressure using a finite difference method
! to compute the thickness weighted pressure gradient at the 
! velocity cell point. 
!
! For pressure-like vertical coordinates, we omit the bottom pressure
! and bottom geopotential.  Account is taken of variable partial cell
! thickness.  1 = dp/dx; 2 = dp/dy
!
! Thickness weight since this is what we wish to use in update of 
! the velocity. Resulting thickness weighted pressure gradient has 
! dimensions of Pa = N/m^2 = kg/(m*s^2).
!
! Thickness%dzu should be at tau.
!
! </DESCRIPTION>
!
subroutine pressure_gradient_force_press(Time, Thickness, Dens, Velocity, rho)

  type(ocean_time_type),          intent(in)    :: Time
  type(ocean_thickness_type),     intent(in)    :: Thickness
  type(ocean_density_type),       intent(in)    :: Dens
  type(ocean_velocity_type),      intent(inout) :: Velocity
  real, dimension(isd:,jsd:,:),   intent(in)    :: rho

  real, dimension(isd:ied,jsd:jed) :: diff_press_x
  real, dimension(isd:ied,jsd:jed) :: diff_press_y
  real, dimension(isd:ied,jsd:jed) :: tmp1
  real, dimension(isd:ied,jsd:jed) :: tmp2
  integer :: i, j, k
  integer :: tau

  if ( .not. module_is_initialized ) then 
    call mpp_error(FATAL, &
    '==>Error in ocean_pressure_mod (pressure_gradient_force_press): module must be initialized')
  endif 

  tau    = Time%tau
  tmp1   = 0.0
  tmp2   = 0.0
  wrk1_v = 0.0
  wrk2_v = 0.0

  ! use density anomaly to improve accuracy 
  do k=1,nk
     do j=jsd,jed
        do i=isd,ied
           wrk2(i,j,k) = Grd%tmask(i,j,k)*(rho(i,j,k)-rho0)
        enddo
     enddo
  enddo

  ! compute geopotential anomaly (m^2/s^2) at T-cell point 
  wrk1(:,:,:) = geopotential_anomaly(Thickness, wrk2(:,:,:)) 

  if(id_anomgeopot > 0) then 
      used = send_data( id_anomgeopot, wrk1(:,:,:), &
           Time%model_time, rmask=Grd%tmask(:,:,:), &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif

  diff_press_x(:,:) = 0.0
  diff_press_y(:,:) = 0.0

  do k=1,nk

     do j=jsd,jed
        do i=isd,iec
           diff_press_x(i,j) = -dbars2pa*(Dens%pressure_at_depth(i+1,j,k)-Dens%pressure_at_depth(i,j,k))
        enddo
     enddo
     do j=jsd,jec
        do i=isd,ied
           diff_press_y(i,j) = -dbars2pa*(Dens%pressure_at_depth(i,j+1,k)-Dens%pressure_at_depth(i,j,k))
        enddo
     enddo

     ! anomalous density times gradient of pressure on k-level               
     ! (dzurhoprime_pgrad_x_klev,dzurhoprime_pgrad_y_klev)
     tmp1(:,:) = rho0r*FAY(FAX(wrk2(:,:,k))*diff_press_x(:,:))
     tmp2(:,:) = rho0r*FAX(FAY(wrk2(:,:,k))*diff_press_y(:,:))
     do j=jsc,jec
        do i=isc,iec
           wrk1_v(i,j,k,1) = tmp1(i,j)*Grd%dxur(i,j)*Thickness%dzu(i,j,k)
           wrk1_v(i,j,k,2) = tmp2(i,j)*Grd%dyur(i,j)*Thickness%dzu(i,j,k)
        enddo
     enddo

     ! density times gradient of anomalous geopotential on k-level
     ! (dzurho_geogradprime_x_klev,dzurho_geogradprime_y_klev) 
     tmp1(:,:) = FDX_NT(FAY(wrk1(:,:,k)))
     tmp2(:,:) = FDY_ET(FAX(wrk1(:,:,k)))
     do j=jsc,jec
        do i=isc,iec
           wrk2_v(i,j,k,1) = tmp1(i,j)*Thickness%rho_dzu(i,j,k,tau)
           wrk2_v(i,j,k,2) = tmp2(i,j)*Thickness%rho_dzu(i,j,k,tau)
        enddo
     enddo

     ! thickness weighted baroclinic pressure gradient on z-levels
     ! (dzu_pgrad_u,dzu_pgrad_v)
     do j=jsc,jec
        do i=isc,iec    
           Velocity%press_force(i,j,k,1) = -Grd%umask(i,j,k)*( wrk1_v(i,j,k,1) + wrk2_v(i,j,k,1) )
           Velocity%press_force(i,j,k,2) = -Grd%umask(i,j,k)*( wrk1_v(i,j,k,2) + wrk2_v(i,j,k,2) )
        enddo
     enddo

  enddo  ! k do-loop finish 


  ! (dzurhoprime_pgrad_x_klev,dzurhoprime_pgrad_y_klev)
  if (id_rhoprime_pgrad_klev(1) > 0) then 
      used = send_data(id_rhoprime_pgrad_klev(1),wrk1_v(:,:,:,1), &
           Time%model_time, rmask=Grd%umask(:,:,:),               &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif
  if (id_rhoprime_pgrad_klev(2) > 0) then 
      used = send_data(id_rhoprime_pgrad_klev(2),wrk1_v(:,:,:,2), &
           Time%model_time, rmask=Grd%umask(:,:,:),               &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif

  ! (dzurho_geogradprime_x_klev,dzurho_geogradprime_y_klev)
  if (id_rho_geogradprime_klev(1) > 0) then 
      used=send_data(id_rho_geogradprime_klev(1),wrk2_v(:,:,:,1), &
           Time%model_time, rmask=Grd%umask(:,:,:),               &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif
  if (id_rho_geogradprime_klev(2) > 0) then 
      used=send_data(id_rho_geogradprime_klev(2),wrk2_v(:,:,:,2), &
           Time%model_time, rmask=Grd%umask(:,:,:),               &
           is_in=isc, js_in=jsc, ks_in=1, ie_in=iec, je_in=jec, ke_in=nk)
  endif


end subroutine pressure_gradient_force_press
! </SUBROUTINE> NAME="pressure_gradient_force_press"


!#######################################################################
! <FUNCTION NAME="pressure_in_dbars">
!
! <DESCRIPTION>
! Compute pressure (dbars) exerted at T cell grid point by weight of
! water column above the grid point. 
!
! rho = density in kg/m^3
!
! psurf = surface pressure in Pa= kg/(m*s^2) = hydrostatic pressure 
! at z=0 associated with fluid between z=0 and z=eta_t.
! Also include pressure from atmosphere and ice, both of which 
! are part of the patm array. 
!
! This routine is used by ocean_density to compute the pressure 
! used in the equation of state.  It is only called when the 
! vertical coordinate is DEPTH_BASED.
!
! </DESCRIPTION>
function pressure_in_dbars (Thickness, rho, psurf)

  type(ocean_thickness_type),   intent(in) :: Thickness
  real, dimension(isd:,jsd:,:), intent(in) :: rho   
  real, dimension(isd:,jsd:),   intent(in) :: psurf 
  real, dimension(isd:ied,jsd:jed,nk)      :: pressure_in_dbars
  integer :: k

  if ( .not. module_is_initialized ) then   
    call mpp_error(FATAL, &
    '==>Error in ocean_pressure_mod (pressure_in_dbars): module must be initialized')
  endif 

  pressure_in_dbars(:,:,:) = hydrostatic_pressure (Thickness, rho(:,:,:))*c2dbars

  ! add pressure from free surface height and loading from atmosphere and/or sea ice
  do k=1,nk
     pressure_in_dbars(:,:,k) = pressure_in_dbars(:,:,k) + psurf(:,:)*c2dbars 
  enddo


end function pressure_in_dbars
! </FUNCTION> NAME="pressure_in_dbars"


!#######################################################################
! <FUNCTION NAME="hydrostatic_pressure">
!
! <DESCRIPTION>
! Hydrostatic pressure [Pa=N/m^2=kg/(m*s^2)] at T cell grid points.
!
! For GEOPOTENTIAL vertical coordinate, integration is 
! from z=0 to depth of grid point.  This integration results in  
! the so-called "baroclinic" pressure. 
!
! For ZSTAR or ZSIGMA, vertical coordinate, integration is from z=eta to 
! depth of grid point.  This is allowed because ZSTAR and ZSIGMA 
! absorb the undulations of the surface height into their definition.
!
! If the input density "rho" is an anomoly, the resulting presure 
! will be a hydrostatic pressure anomoly. If "rho" is full density, 
! the presure will be a full hydrostatic pressure.
!
! </DESCRIPTION>
!
function hydrostatic_pressure (Thickness, rho)

  type(ocean_thickness_type),   intent(in) :: Thickness
  real, dimension(isd:,jsd:,:), intent(in) :: rho

  integer :: i, j, k
  real, dimension(isd:ied,jsd:jed,nk) :: hydrostatic_pressure

  if(vert_coordinate==GEOPOTENTIAL) then 
      do j=jsd,jed
         do i=isd,ied
            hydrostatic_pressure(i,j,1) = rho(i,j,1)*grav*Grd%dzw(0)
         enddo
      enddo
  elseif(vert_coordinate==ZSTAR .or. vert_coordinate==ZSIGMA) then 
      do j=jsd,jed
         do i=isd,ied
            hydrostatic_pressure(i,j,1) = rho(i,j,1)*grav*Thickness%dzwt(i,j,0)
         enddo
      enddo
  endif

  if(Thickness%method==ENERGETIC) then 

      do k=2,nk
         do j=jsd,jed
            do i=isd,ied
               hydrostatic_pressure(i,j,k) = hydrostatic_pressure(i,j,k-1) &
               + Grd%tmask(i,j,k)*p5grav                                   &
                *(rho(i,j,k-1)+rho(i,j,k))*Thickness%dzwt(i,j,k-1) 
            enddo
         enddo
      enddo

  elseif(Thickness%method==FINITEVOLUME) then 

      do k=2,nk
         do j=jsd,jed
            do i=isd,ied
               hydrostatic_pressure(i,j,k) = hydrostatic_pressure(i,j,k-1) &
               + Grd%tmask(i,j,k)*grav                                     &
                *(Thickness%dztlo(i,j,k-1)*rho(i,j,k-1)+Thickness%dztup(i,j,k)*rho(i,j,k)) 
            enddo
         enddo
      enddo

  endif

  ! For some debugging...we here drop the contribution from a 
  ! nonzero eta in the calculation of hydrostatic_pressure. 
  ! This is wrong physically, but it is useful for certain tests
  ! of the zstar vertical coordinate.  
  if(vert_coordinate==ZSTAR .and. zero_eta_over_h_zstar_pressure) then 
      do j=jsd,jed
         do i=isd,ied
            hydrostatic_pressure(i,j,1) = rho(i,j,1)*grav*Thickness%dswt(i,j,0)
         enddo
      enddo
      do k=2,nk
         do j=jsd,jed
            do i=isd,ied
               hydrostatic_pressure(i,j,k) = hydrostatic_pressure(i,j,k-1) &
               + Grd%tmask(i,j,k)*p5grav                                   &
                *(rho(i,j,k-1)+rho(i,j,k))*Thickness%dswt(i,j,k-1) 
            enddo
         enddo
      enddo
  endif 


end function hydrostatic_pressure
! </FUNCTION> NAME="hydrostatic_pressure"



!#######################################################################
! <FUNCTION NAME="geopotential_anomaly">
!
! <DESCRIPTION>
! Geopotential anomaly [m^2/s^2] at T cell grid points.
! Integration here is from z=-H to depth of grid point.  
!
! Input should be density anomaly rhoprime = rho-rho0.
!
! This function is needed when computing pressure gradient
! for PRESSURE_BASED vertical coordinates. 
!
! WARNING: Thickness%method==FINITEVOLUME has been found to be 
! problematic.  It remains under development.  It is NOT 
! supported for general use. 
! 
! </DESCRIPTION>
!
function geopotential_anomaly (Thickness, rhoprime)

  type(ocean_thickness_type),   intent(in) :: Thickness
  real, dimension(isd:,jsd:,:), intent(in) :: rhoprime

  integer :: i, j, k, kbot
  real, dimension(isd:ied,jsd:jed,nk) :: geopotential_anomaly 
  
  geopotential_anomaly(:,:,:) = 0.0

  if(Thickness%method==ENERGETIC) then 
      do j=jsd,jed
         do i=isd,ied
            kbot=Grd%kmt(i,j)
            if(kbot > 1) then  
                k=kbot
                geopotential_anomaly(i,j,k) = -grav_rho0r*rhoprime(i,j,k)*Thickness%dzwt(i,j,k) 
                do k=kbot-1,1,-1
                   geopotential_anomaly(i,j,k) = geopotential_anomaly(i,j,k+1) &
                   -p5grav_rho0r*(rhoprime(i,j,k+1)+rhoprime(i,j,k))*Thickness%dzwt(i,j,k)
                enddo
            endif
         enddo
      enddo
  elseif(Thickness%method==FINITEVOLUME) then 
      do j=jsd,jed
         do i=isd,ied
            kbot=Grd%kmt(i,j)
            if(kbot > 1) then
                k=kbot
                geopotential_anomaly(i,j,k) = -grav_rho0r*rhoprime(i,j,k)*Thickness%dztlo(i,j,k)   
                do k=kbot-1,1,-1
                   geopotential_anomaly(i,j,k) = geopotential_anomaly(i,j,k+1) &
                   -grav_rho0r*(Thickness%dztlo(i,j,k)*rhoprime(i,j,k)+Thickness%dztup(i,j,k+1)*rhoprime(i,j,k+1)) 
                enddo
            endif
         enddo
      enddo
  endif

end function geopotential_anomaly
! </FUNCTION> NAME="geopotential_anomaly"


end module ocean_pressure_mod
