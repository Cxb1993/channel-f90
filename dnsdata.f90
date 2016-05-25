!============================================!
!                                            !
!    Data Structures, Definitions and I/O    !
!                  for the                   !
!     Direct Numerical Simulation (DNS)      !
!        of a turbulent channel flow         !
!                                            !
!============================================!
! 
! Author: Dr.-Ing. Davide Gatti
! Date  : 28/Jul/2015
! 

! Force (nxd,nzd) to be at most the product of a
! power of 2 and a single factor 3.
#define useFFTfit

! Activate the body forcing for impulse response
!#define IMPULSE
!#define fx


MODULE dnsdata

  USE, intrinsic :: iso_c_binding
  USE rbmat
  USE ffts
  IMPLICIT NONE

  !Simulation parameters
  real(C_DOUBLE) :: PI=3.1415926535897932384626433832795028841971
  integer(C_INT) :: nx,ny,nz,nxd,nzd
  real(C_DOUBLE) :: alfa0,beta0,ni,a,ymin,ymax,deltat,cflmax,time,dt_field,dt_save,t_max
  real(C_DOUBLE) :: meanpx,meanpz,meanflowx,meanflowz
  integer(C_INT), allocatable :: izd(:)
  complex(C_DOUBLE_COMPLEX), allocatable :: ialfa(:),ibeta(:)
  real(C_DOUBLE), allocatable :: k2(:,:)
  !Restart parameters

  !Impulse response parameters
#ifdef IMPULSE
  integer(C_INT) :: nxh,nzh,ndtresp,iyforcing
  real(C_DOUBLE) :: Amp
  logical :: restart_flag
#ifdef fx
  TYPE(VETA), allocatable :: Hx(:,:,:,:)
#endif
#ifdef fy
  TYPE(VETA), allocatable :: Hy(:,:,:,:)
#endif
#ifdef fz
  TYPE(VETA), allocatable :: Hz(:,:,:,:)
#endif
  complex(C_DOUBLE_COMPLEX), allocatable :: F(:,:,:,:), history(:,:,:,:)
#endif
  !Grid
  integer(C_INT), private :: iy
  real(C_DOUBLE), allocatable :: y(:),dy(:)
  real(C_DOUBLE) :: dx,dz,factor
  !Derivatives
  TYPE(Di), allocatable :: der(:)
  real(C_DOUBLE), dimension(-2:2) :: d040,d140,d14m1,d04n,d14n,d24n,d14np1
  real(C_DOUBLE), allocatable :: D0mat(:,:), etamat(:,:), D2vmat(:,:)
  !Fourier-transformable arrays (allocated in ffts.f90)
  complex(C_DOUBLE_COMPLEX), pointer, dimension(:,:,:,:) :: VVd
  real(C_DOUBLE), pointer, dimension(:,:,:,:) :: rVVd
  !Solution
  TYPE(RHSTYPE),  allocatable :: memrhs(:,:,:), oldrhs(:,:,:)
  complex(C_DOUBLE_COMPLEX), allocatable :: V(:,:,:,:)
  !Boundary conditions
  real(C_DOUBLE), dimension(-2:2) :: v0bc,v0m1bc,vnbc,vnp1bc,eta0bc,eta0m1bc,etanbc,etanp1bc
  TYPE(BCOND),    allocatable :: bc0(:,:), bcn(:,:)
  !Mean pressure correction
  real(C_DOUBLE), private :: corrpx=0.d0, corrpz=0.d0
  !ODE Library
  real(C_DOUBLE) :: RK1_rai(1:3)=(/ 120.0d0/32.0d0, 2.0d0, 0.0d0 /), &
                    RK2_rai(1:3)=(/ 120.0d0/8.0d0,  50.0d0/8.0d0,   34.0d0/8.0d0 /), &
                    RK3_rai(1:3)=(/ 120.0d0/20.0d0, 90.0d0/20.0d0, 50.0d0/20.0d0 /)
  !Outstats
  real(C_DOUBLE) :: cfl=0.0d0

  CONTAINS

  !--------------------------------------------------------------!
  !---------------------- Read input files ----------------------!
  SUBROUTINE read_dnsin()
    logical :: i
    OPEN(15, file='dns.in')
    READ(15, *) nx, ny, nz; READ(15, *) alfa0, beta0; nxd=3*nx/2;nzd=3*nz
#ifdef useFFTfit
    i=fftFIT(nxd); DO WHILE (.NOT. i); nxd=nxd+1; i=fftFIT(nxd); END DO
    i=fftFIT(nzd); DO WHILE (.NOT. i); nzd=nzd+1; i=fftFIT(nzd); END DO
#endif
    READ(15, *) ni; READ(15, *) a, ymin, ymax; ni=1/ni
    READ(15, *) meanpx, meanpz; READ(15, *) meanflowx, meanflowz
    READ(15, *) deltat, cflmax, time
    READ(15, *) dt_field, dt_save, t_max
#ifdef IMPULSE
    READ(15, *) nxh, nzh, ndtresp
    READ(15, *) Amp, iyforcing
#endif
    CLOSE(15)
    dx=PI/(alfa0*nxd); dz=2.0d0*PI/(beta0*nzd);  factor=1.0d0/(2.0d0*nxd*nzd)
  END SUBROUTINE read_dnsin

  !--------------------------------------------------------------!
  !---------------- Allocate memory for solution ----------------!
  SUBROUTINE init_memory()
    INTEGER(C_INT) :: ix,iz
    ALLOCATE(V(-1:ny+1,0:nx,-nz:nz,1:3))
    ALLOCATE(memrhs(0:2,0:nx,-nz:nz),oldrhs(1:ny-1,0:nx,-nz:nz),bc0(0:nx,-nz:nz),bcn(0:nx,-nz:nz))
#define newrhs(iy,ix,iz) memrhs(MOD(iy+1000,3),ix,iz)
#define imod(iy) MOD(iy+1000,5)
    ALLOCATE(der(1:ny-1),d0mat(1:ny-1,-2:2),etamat(1:ny-1,-2:2),D2vmat(1:ny-1,-2:2),y(-1:ny+1),dy(1:ny-1))
    ALLOCATE(izd(-nz:nz),ialfa(0:nx),ibeta(-nz:nz),k2(0:nx,-nz:nz))
    y=(/(ymin+0.5d0*(ymax-ymin)*(tanh(a*(2.0d0*real(iy)/real(ny)-1))/tanh(a)+0.5d0*(ymax-ymin)), iy=-1, ny+1)/)
    dy=(/( 0.5d0*(y(iy+1)-y(iy-1)) , iy=1, ny-1)/)
    izd=(/(merge(iz,nzd+iz,iz>=0),iz=-nz,nz)/);     ialfa=(/(dcmplx(0.0d0,ix*alfa0),ix=0,nx)/);
    ibeta=(/(dcmplx(0.0d0,iz*beta0),iz=-nz,nz)/); 
    FORALL  (ix=0:nx, iz=-nz:nz) k2(ix,iz)=(alfa0*ix)**2.0d0+(beta0*iz)**2.0d0
#ifdef IMPULSE
    ALLOCATE(F(-1:ny+1,0:nx,-nz:nz,1:3),history(0:ndtresp,0:nxh,-nzh:nzh,1:3))
#ifdef fx
    ALLOCATE(Hx(0:ndtresp,0:ny,0:nxh,-nzh:nzh))
#endif
#ifdef fy
    ALLOCATE(Hy(0:ndtresp,0:ny,0:nxh,-nzh:nzh))
#endif
#ifdef fz
    ALLOCATE(Hz(0:ndtresp,0:ny,0:nxh,-nzh:nzh))
#endif
#endif
  END SUBROUTINE init_memory

  !--------------------------------------------------------------!
  !------------- Subroutines for impulse response ---------------!
#ifdef IMPULSE
  !--------------------------------------------------------------!
  !-------------- Updating the body forcing (WN)  ---------------!
  SUBROUTINE update_noise()
    integer(C_INT) :: it,ix,iz
    real(C_DOUBLE) :: rn(1:3)
    DO it=ndtresp,1,-1
      history(:,:,it,:)=history(:,:,it-1,:)
    END DO
    DO iz=0,nzh ! XXX also (ix,iz)=(0,0)?
      DO ix=0,nxh
        CALL RANDOM_NUMBER(rn)
#ifdef fx
        F(iyforcing,ix,iz,1) = Amp*EXP(dcmplx(0,rn(1)*2*PI))
#endif
#ifdef fy
        F(iyforcing,ix,iz,2) = Amp*EXP(dcmplx(0,rn(2)*2*PI))
#endif
#ifdef fz
        F(iyforcing,ix,iz,3) = Amp*EXP(dcmplx(0,rn(3)*2*PI))
#endif
      END DO
    END DO
    DO CONCURRENT (iz=1:nz)
#ifdef fx
      F(iyforcing,0,-iz,1) = CONJG(F(iyforcing,0,iz,1))
#endif
#ifdef fy
      F(iyforcing,0,-iz,2) = CONJG(F(iyforcing,0,iz,2))
#endif
#ifdef fz
      F(iyforcing,0,-iz,3) = CONJG(F(iyforcing,0,iz,3))
#endif
    END DO
    history(0,:,:,:)=CONJG(F(iyforcing,:,:,:)) ! XXX check indices
  END SUBROUTINE update_noise

  !------------------------------------------------------------!
  !------------ Updating input-output correlation -------------!
  SUBROUTINE update_correlation()
    integer(C_INT) :: it,ix,iz
    DO it=ndtresp,1,-1
      history(:,:,it,:)=history(:,:,it-1,:)
    END DO
    DO CONCURRENT (it=0:ndtresp,iy=0:ny,ix=0:nxh,iz=-nzh:nzh)
#ifdef fx
      Hx(it,iy,ix,iz)%v   = Hx(it,iy,ix,iz)%v   + V(iy,ix,iz,2)*history(it,ix,iz,1)
      Hx(it,iy,ix,iz)%eta = Hx(it,iy,ix,iz)%eta + (ibeta(iz)*V(iy,ix,iz,1)-ialfa(ix)*V(iy,ix,iz,3))*history(it,ix,iz,1)
#endif
#ifdef fy
      Hy(it,iy,ix,iz)%v   = Hy(it,iy,ix,iz)%v   + V(iy,ix,iz,2)*history(it,ix,iz,2)
      Hy(it,iy,ix,iz)%eta = Hy(it,iy,ix,iz)%eta + (ibeta(iz)*V(iy,ix,iz,1)-ialfa(ix)*V(iy,ix,iz,3))*history(it,ix,iz,2)
#endif
#ifdef fz
      Hz(it,iy,ix,iz)%v   = Hz(it,iy,ix,iz)%v   + V(iy,ix,iz,2)*history(it,ix,iz,3)
      Hz(it,iy,ix,iz)%eta = Hz(it,iy,ix,iz)%eta + (ibeta(iz)*V(iy,ix,iz,1)-ialfa(ix)*V(iy,ix,iz,3))*history(it,ix,iz,3)
#endif  
    END DO
  END SUBROUTINE update_correlation
#endif
  !---------- End of Subroutines for impulse response -----------!
  !--------------------------------------------------------------!


  !--------------------------------------------------------------!
  !--------------- Deallocate memory for solution ---------------!
  SUBROUTINE free_memory()
    DEALLOCATE(V,memrhs,oldrhs,der,bc0,bcn,d0mat,etamat,D2vmat,y,dy)
  END SUBROUTINE free_memory

  !--------------------------------------------------------------!
  !--------------- Set-up the compact derivatives ---------------!
  SUBROUTINE setup_derivatives()
    real(C_DOUBLE) :: M(0:4,0:4), t(0:4)
    integer(C_INT) :: iy,i,j
    DO iy=1,ny-1
      FORALL (i=0:4, j=0:4) M(i,j)=(y(iy-2+j)-y(iy))**(4.0d0-i); CALL LUdecomp(M)
      t=0; t(0)=24
      der(iy)%d4(-2:2)=M.bs.t
      FORALL (i=0:4, j=0:4) M(i,j)=(5.0d0-i)*(6.0d0-i)*(7.0d0-i)*(8.0d0-i)*(y(iy-2+j)-y(iy))**(4.0d0-i); CALL LUdecomp(M)
      FORALL (i=0:4) t(i)=sum( der(iy)%d4(-2:2)*(y(iy-2:iy+2)-y(iy))**(8.0d0-i) )
      der(iy)%d0(-2:2)=M.bs.t
      FORALL (i=0:4, j=0:4) M(i,j)=(y(iy-2+j)-y(iy))**(4.0d0-i); CALL LUdecomp(M)
      t=0; FORALL (i=0:2) t(i)=sum( der(iy)%d0(-2:2)*(4.0d0-i)*(3.0d0-i)*(y(iy-2:iy+2)-y(iy))**(2.0d0-i) )
      der(iy)%d2(-2:2)=M.bs.t
      t=0; FORALL (i=0:3) t(i)=sum( der(iy)%d0(-2:2)*(4.0d0-i)*(y(iy-2:iy+2)-y(iy))**(3.0d0-i) )
      der(iy)%d1(-2:2)=M.bs.t
    END DO
    FORALL (i=0:4, j=0:4) M(i,j)=(y(-1+j)-y(0))**(4.0d0-i); CALL LUdecomp(M)
    t=0; t(3)=1.0; d140(-2:2)=M.bs.t
    FORALL (i=0:4, j=0:4) M(i,j)=(y(-1+j)-y(-1))**(4.0d0-i); CALL LUdecomp(M)
    t=0; t(3)=1.0; d14m1(-2:2)=M.bs.t
    d04n=0; d04n(1)=1; d040=0; d040(-1)=1
    FORALL (i=0:4, j=0:4) M(i,j)=(y(ny-3+j)-y(ny))**(4.0d0-i); CALL LUdecomp(M)
    t=0; t(3)=1; d14n(-2:2)=M.bs.t
    t=0; t(2)=2; d24n(-2:2)=M.bs.t
    FORALL (i=0:4, j=0:4) M(i,j)=(y(ny-3+j)-y(ny+1))**(4.0d0-i); CALL LUdecomp(M)
    t=0; t(3)=1; d14np1(-2:2)=M.bs.t
    FORALL (iy=1:ny-1) D0mat(iy,-2:2)=der(iy)%d0(-2:2); CALL LU5decomp(D0mat)
  END SUBROUTINE setup_derivatives

  !--------------------------------------------------------------!
  !--------------- Set-up the boundary conditions ---------------!
  SUBROUTINE setup_boundary_conditions()
    v0bc=d040; v0m1bc=d140; eta0bc=d040
    vnbc=d04n; vnp1bc=d14n; etanbc=d04n
    etanp1bc=der(ny-1)%d4
    eta0m1bc=der(1)%d4
    v0bc(-1:2)=v0bc(-1:2)-v0bc(-2)*v0m1bc(-1:2)/v0m1bc(-2)
    eta0bc(-1:2)=eta0bc(-1:2)-eta0bc(-2)*eta0m1bc(-1:2)/eta0m1bc(-2)
    vnbc(-2:1)=vnbc(-2:1)-vnbc(2)*vnp1bc(-2:1)/vnp1bc(2)
    etanbc(-2:1)=etanbc(-2:1)-etanbc(2)*etanp1bc(-2:1)/etanp1bc(2)
  END SUBROUTINE setup_boundary_conditions

  !--------------------------------------------------------------!
  !---------------- integral in the y-direction -----------------!
  PURE FUNCTION yintegr(f) result(II)
    real(C_DOUBLE), intent(in) :: f(-1:ny+1)
    real(C_DOUBLE) :: II, yp1, ym1, a1, a2, a3
    integer(C_INT) :: iy
    II=0.0d0
    DO iy=1,ny-1,2
      yp1=y(iy+1)-y(iy); ym1=y(iy-1)-y(iy)
      a1=-1.0d0/3.0d0*ym1+1.0d0/6.0d0*yp1+1.0d0/6.0d0*yp1*yp1/ym1
      a3=+1.0d0/3.0d0*yp1-1.0d0/6.0d0*ym1-1.0d0/6.0d0*ym1*ym1/yp1
      a2=yp1-ym1-a1-a3
      II=II+a1*f(iy-1)+a2*f(iy)+a3*f(iy+1)
    END DO
  END FUNCTION yintegr

#define rD0(f,g,k) sum(dcmplx(der(iy)%d0(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d0(-2:2)*dreal(f(-2:2,k,ix))))
#define rD1(f,g,k) sum(dcmplx(der(iy)%d1(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d1(-2:2)*dreal(f(-2:2,k,ix))))
#define rD2(f,g,k) sum(dcmplx(der(iy)%d2(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d2(-2:2)*dreal(f(-2:2,k,ix))))
#define rD4(f,g,k) sum(dcmplx(der(iy)%d4(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d4(-2:2)*dreal(f(-2:2,k,ix))))
#define D0(f,g) sum(dcmplx(der(iy)%d0(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d0(-2:2)*dimag(f(-2:2,g,ix))))
#define D1(f,g) sum(dcmplx(der(iy)%d1(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d1(-2:2)*dimag(f(-2:2,g,ix))))
#define D2(f,g) sum(dcmplx(der(iy)%d2(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d2(-2:2)*dimag(f(-2:2,g,ix))))
#define D4(f,g) sum(dcmplx(der(iy)%d4(-2:2)*dreal(f(-2:2,g,ix)) ,der(iy)%d4(-2:2)*dimag(f(-2:2,g,ix))))
  !--------------------------------------------------------------!
  !---COMPLEX----- derivative in the y-direction ----------------!
  SUBROUTINE COMPLEXderiv(f0,f1)
    complex(C_DOUBLE_COMPLEX), intent(in)  :: f0(-1:ny+1)
    complex(C_DOUBLE_COMPLEX), intent(out) :: f1(-1:ny+1)
    f1(0)=sum(d140(-2:2)*f0(-1:3))
    f1(-1)=sum(d14m1(-2:2)*f0(-1:3))
    f1(ny)=sum(d14n(-2:2)*f0(ny-3:ny+1))
    f1(ny+1)=sum(d14np1(-2:2)*f0(ny-3:ny+1))
    DO CONCURRENT (iy=1:ny-1)
      f1(iy)=sum(der(iy)%d1(-2:2)*f0(iy-2:iy+2))
    END DO
    f1(1)=f1(1)-(der(1)%d0(-1)*f1(0)+der(1)%d0(-2)*f1(-1))
    f1(2)=f1(2)-der(2)%d0(-2)*f1(0)
    f1(ny-1)=f1(ny-1)-(der(ny-1)%d0(1)*f1(ny)+der(ny-1)%d0(2)*f1(ny+1))
    f1(ny-2)=f1(ny-2)-der(ny-2)%d0(2)*f1(ny)
    !f1(1:ny-1)=dcmplx(D0mat.bsr.dreal(f1(1:ny-1)),D0mat.bsr.dimag(f1(1:ny-1)))
    CALL LeftLU5div(D0mat,f1(1:ny-1))
  END SUBROUTINE COMPLEXderiv

  !--------------------------------------------------------------!
  !----------------- apply the boundary conditions --------------!
  PURE SUBROUTINE applybc_0(EQ,bc0,bc0m1)
    real(C_DOUBLE), intent(inout) :: EQ(1:ny-1,-2:2)
    real(C_DOUBLE), intent(in) :: bc0(-2:2),bc0m1(-2:2)
    EQ(1,-1:2)=EQ(1,-1:2)-EQ(1,-2)*bc0m1(-1:2)/bc0m1(-2)
    EQ(1, 0:2)=EQ(1, 0:2)-EQ(1,-1)*bc0(0:2)/bc0(-1)
    EQ(2,-1:1)=EQ(2,-1:1)-EQ(2,-2)*bc0(0:2)/bc0(-1)
  END SUBROUTINE applybc_0

  PURE SUBROUTINE applybc_n(EQ,bcn,bcnp1)
    real(C_DOUBLE), intent(inout) :: EQ(1:ny-1,-2:2)
    real(C_DOUBLE), intent(in) :: bcn(-2:2),bcnp1(-2:2)
    EQ(ny-1,-2:1)=EQ(ny-1,-2:1)-EQ(ny-1,2)*bcnp1(-2:1)/bcnp1(2)
    EQ(ny-1,-2:0)=EQ(ny-1,-2:0)-EQ(ny-1,1)*bcn(-2:0)/bcn(1)
    EQ(ny-2,-1:1)=EQ(ny-2,-1:1)-EQ(ny-2,2)*bcn(-2:0)/bcn(1)
  END SUBROUTINE applybc_n


#define OS(iy,j) (ni*(der(iy)%d4(j)-2.0d0*k2(ix,iz)*der(iy)%d2(j)+k2(ix,iz)*k2(ix,iz)*der(iy)%d0(j)))
#define SQ(iy,j) (ni*(der(iy)%d2(j)-k2(ix,iz)*der(iy)%d0(j)))
  !--------------------------------------------------------------!
  !------------------- solve the linear system  -----------------!
  SUBROUTINE linsolve(lambda)
    real(C_DOUBLE), intent(in) :: lambda
    integer(C_INT) :: ix,iz
    complex(C_DOUBLE_COMPLEX) :: temp(-1:ny+1)
    real(C_DOUBLE) :: ucor(-1:ny+1)
    DO iz=-nz,nz
      DO ix=0,nx
        IF (ix==0 .AND. iz==0) THEN
          bc0(ix,iz)%v=0; bc0(ix,iz)%vy=0; bc0(ix,iz)%eta=dcmplx(dreal(bc0(ix,iz)%u)-dimag(bc0(ix,iz)%w),dimag(bc0(ix,iz)%u)+dreal(bc0(ix,iz)%w))
          bcn(ix,iz)%v=0; bcn(ix,iz)%vy=0; bcn(ix,iz)%eta=dcmplx(dreal(bcn(ix,iz)%u)-dimag(bcn(ix,iz)%w),dimag(bcn(ix,iz)%u)+dreal(bcn(ix,iz)%w))
        ELSE
          bc0(ix,iz)%vy=-ialfa(ix)*bc0(ix,iz)%u-ibeta(iz)*bc0(ix,iz)%w; bc0(ix,iz)%eta=ibeta(iz)*bc0(ix,iz)%u-ialfa(ix)*bc0(ix,iz)%w
          bcn(ix,iz)%vy=-ialfa(ix)*bcn(ix,iz)%u-ibeta(iz)*bcn(ix,iz)%w; bcn(ix,iz)%eta=ibeta(iz)*bcn(ix,iz)%u-ialfa(ix)*bcn(ix,iz)%w
        END IF
        bc0(ix,iz)%v=bc0(ix,iz)%v-v0bc(-2)*bc0(ix,iz)%vy/v0m1bc(-2)
        bcn(ix,iz)%v=bcn(ix,iz)%v-vnbc(2)*bcn(ix,iz)%vy/vnp1bc(2)
        DO CONCURRENT (iy=1:ny-1)
          D2vmat(iy,-2:2)=lambda*(der(iy)%d2(-2:2)-k2(ix,iz)*der(iy)%d0(-2:2))-OS(iy,-2:2)
          etamat(iy,-2:2)=lambda*der(iy)%d0(-2:2)-SQ(iy,-2:2)
        END DO
        CALL applybc_0(D2vmat,v0bc,v0m1bc)
        CALL applybc_n(D2vmat,vnbc,vnp1bc)
        V(1,ix,iz,2)=V(1,ix,iz,2)-D2vmat(1,-2)*bc0(ix,iz)%vy/v0m1bc(-2)-D2vmat(1,-1)*bc0(ix,iz)%v/v0bc(-1)
        V(2,ix,iz,2)=V(2,ix,iz,2)-D2vmat(2,-2)*bc0(ix,iz)%v/v0bc(-1)       
        V(ny-1,ix,iz,2)=V(ny-1,ix,iz,2)-D2vmat(ny-1,2)*bcn(ix,iz)%vy/vnp1bc(2)-D2vmat(ny-1,1)*bcn(ix,iz)%v/vnbc(1)
        V(ny-2,ix,iz,2)=V(ny-2,ix,iz,2)-D2vmat(ny-2,2)*bcn(ix,iz)%v/vnbc(1)
        CALL applybc_0(etamat,eta0bc,eta0m1bc)
        CALL applybc_n(etamat,etanbc,etanp1bc)
        V(1,ix,iz,1)=V(1,ix,iz,1)-etamat(1,-1)*bc0(ix,iz)%eta/eta0bc(-1)
        V(2,ix,iz,1)=V(2,ix,iz,1)-etamat(2,-2)*bc0(ix,iz)%eta/eta0bc(-1)
        V(ny-1,ix,iz,1)=V(ny-1,ix,iz,1)-etamat(ny-1,1)*bcn(ix,iz)%eta/etanbc(1)
        V(ny-2,ix,iz,1)=V(ny-2,ix,iz,1)-etamat(ny-2,2)*bcn(ix,iz)%eta/etanbc(1)
        CALL LU5decomp(D2vmat); CALL LU5decomp(etamat)
        CALL LeftLU5div(D2vmat,V(1:ny-1,ix,iz,2))
        V(0,ix,iz,2)=(bc0(ix,iz)%v-sum(V(1:3,ix,iz,2)*v0bc(0:2)))/v0bc(-1)
        V(-1,ix,iz,2)=(bc0(ix,iz)%vy-sum(V(0:3,ix,iz,2)*v0m1bc(-1:2)))/v0m1bc(-2)
        V(ny,ix,iz,2)=(bcn(ix,iz)%v-sum(V(ny-3:ny-1,ix,iz,2)*vnbc(-2:0)))/vnbc(1)
        V(ny+1,ix,iz,2)=(bcn(ix,iz)%vy-sum(V(ny-3:ny,ix,iz,2)*vnp1bc(-2:1)))/vnp1bc(2)
        CALL LeftLU5div(etamat,V(1:ny-1,ix,iz,1))
        V(0,ix,iz,1)=(bc0(ix,iz)%eta-sum(V(1:3,ix,iz,1)*eta0bc(0:2)))/eta0bc(-1)
        V(-1,ix,iz,1)=-sum(V(0:3,ix,iz,1)*eta0m1bc(-1:2))/eta0m1bc(-2)
        V(ny,ix,iz,1)=(bcn(ix,iz)%eta-sum(V(ny-3:ny-1,ix,iz,1)*etanbc(-2:0)))/etanbc(1)
        V(ny+1,ix,iz,1)=-sum(V(ny-3:ny,ix,iz,1)*etanp1bc(-2:1))/etanp1bc(2)
        IF (ix==0 .AND. iz==0) THEN
            V(:,0,0,3) = dcmplx(dimag(V(:,0,0,1)),0.d0); 
            V(:,0,0,1) = dcmplx(dreal(V(:,0,0,1)),0.d0); 
            ucor(-1:0)=0; ucor(1:ny-1)=1; ucor(ny:ny+1)=0
            ucor(1:ny-1)=etamat.bsr.ucor(1:ny-1)
            ucor(0)=-sum(ucor(1:3)*eta0bc(0:2))/eta0bc(-1)
            ucor(-1)=-sum(ucor(0:3)*eta0m1bc(-1:2))/eta0m1bc(-2)
            ucor(ny)=-sum(ucor(ny-3:ny-1)*etanbc(-2:0))/etanbc(1)
            ucor(ny+1)=-sum(ucor(ny-3:ny)*etanp1bc(-2:1))/etanp1bc(2)          
            IF (abs(meanflowx)>1.0d-7) THEN
              corrpx = (meanflowx-yintegr(dreal(V(:,0,0,1))))/yintegr(ucor)
              V(:,0,0,1)=dcmplx(dreal(V(:,0,0,1))+corrpx*ucor,dimag(V(:,0,0,1)))
            END IF
            IF (abs(meanflowz)>1.0d-7) THEN
              corrpz = (meanflowz-yintegr(dreal(V(:,0,0,3))))/yintegr(ucor)
              V(:,0,0,3)=dcmplx(dreal(V(:,0,0,3))+corrpz*ucor,dimag(V(:,0,0,3)))
            END IF
        ELSE
            CALL COMPLEXderiv(V(:,ix,iz,2),V(:,ix,iz,3))
            temp=(ialfa(ix)*V(:,ix,iz,3)-ibeta(iz)*V(:,ix,iz,1))/k2(ix,iz)
            V(:,ix,iz,3)=(ibeta(iz)*V(:,ix,iz,3)+ialfa(ix)*V(:,ix,iz,1))/k2(ix,iz)
            V(:,ix,iz,1)=temp
        END IF
      END DO
    END DO
  END SUBROUTINE linsolve

 !--------------------------------------------------------------!
 !------------------------ convolutions ------------------------!
 SUBROUTINE convolutions(iy,i,compute_cfl)
    integer(C_INT), intent(in) :: iy,i
    logical, intent(in) :: compute_cfl
    VVd(1:nx+1,1:nz+1,1:3,i)=V(iy,0:nx,0:nz,1:3);         VVd(1:nx+1,nz+2:nzd-nz,1:3,i)=0;
    VVd(1:nx+1,nzd+1-nz:nzd,1:3,i)=V(iy,0:nx,-nz:-1,1:3); VVd(nx+2:nxd+1,1:nzd,1:3,i)=0;
    CALL IFT(VVd(:,:,:,i),rVVd(:,:,:,i))
    IF (compute_cfl .and. iy>=1 .and. iy<=ny-1) THEN
          cfl=max(cfl,(maxval(abs(rVVd(1:2*nxd,1:nzd,1,i)))/dx + &
                       maxval(abs(rVVd(1:2*nxd,1:nzd,2,i)))/dy(iy) +  &
                       maxval(abs(rVVd(1:2*nxd,1:nzd,3,i)))/dz))
    END IF
    rVVd(1:2*nxd,1:nzd,4,i)  = rVVd(1:2*nxd,1:nzd,1,i)  * rVVd(1:2*nxd,1:nzd,2,i)*factor
    rVVd(1:2*nxd,1:nzd,5,i)  = rVVd(1:2*nxd,1:nzd,2,i)  * rVVd(1:2*nxd,1:nzd,3,i)*factor
    rVVd(1:2*nxd,1:nzd,6,i)  = rVVd(1:2*nxd,1:nzd,1,i)  * rVVd(1:2*nxd,1:nzd,3,i)*factor
    rVVd(1:2*nxd,1:nzd,1:3,i)= rVVd(1:2*nxd,1:nzd,1:3,i)* rVVd(1:2*nxd,1:nzd,1:3,i)*factor
    CALL FFT(rVVd(:,:,:,i),VVd(:,:,:,i))
  END SUBROUTINE convolutions


  !--------------------------------------------------------------!
  !-------------------------- buildRHS --------------------------!
  ! (u,v,w) = (1,2,3)
  ! (uu,vv,ww,uv,vw,uw) = (1,2,3,4,5,6)
#define DD(f,k) ( der(iy)%f(-2)*VVm2(k)+der(iy)%f(-1)*VVm1(k)+der(iy)%f(0)*VV0(k)+der(iy)%f(1)*VV1(k)+der(iy)%f(2)*VV2(k) )
#define D4F(g,iy) sum(dcmplx(der(iy)%d4(-2:2)*dreal(f(iy-2:iy+2,ix,iz,g)) ,der(iy)%d4(-2:2)*dimag(f(iy-2:iy+2,ix,iz,g))))
#define timescheme(rhs,old,unkn,impl,expl) rhs=ODE(1)*(unkn)/deltat+(impl)+ODE(2)*(expl)-ODE(3)*(old); old=expl                   
  SUBROUTINE buildrhs(ODE,compute_cfl)
    logical, intent(in) :: compute_cfl
    real(C_DOUBLE), intent(in) :: ODE(1:3)
    integer(C_INT) :: iy,ix,iz,im2,im1,i0,i1,i2
    complex(C_DOUBLE_COMPLEX) :: rhsu,rhsv,rhsw,DD0_6,DD1_6,expl
    complex(C_DOUBLE_COMPLEX), dimension(1:6) :: VVm2,VVm1,VV0,VV1,VV2
    complex(C_DOUBLE_COMPLEX) :: Vplane(-2:2,1:3,0:nx)
#ifdef IMPULSE
    integer(C_INT) :: i
    complex(C_DOUBLE_COMPLEX) :: Fplane(-2:2,1:3,0:nx)
    F(-1:0,:,:,:)=0; F(ny:ny+1,:,:,:)=0;
    DO CONCURRENT (ix=0:nx,iz=-nz:nz,i=1:3)
        F(-1,ix,iz,i)=-D4F(i,1)/der(1)%d4(-2);       
        F(ny+1,ix,iz,i)=-D4F(i,ny-1)/der(ny-1)%d4(2);
    END DO
#endif
    DO iy=-3,ny+1
      IF (iy<=ny-1) THEN
      CALL convolutions(iy+2,imod(iy+2)+1,compute_cfl)
      IF (iy>=1) THEN
        im2=imod(iy-2)+1; im1=imod(iy-1)+1; i0=imod(iy)+1; i1=imod(iy+1)+1; i2=imod(iy+2)+1;
        DO iz=-nz,nz 
        DO CONCURRENT (ix=0:nx) 
          Vplane(:,:,ix)=V(iy-2:iy+2,ix,iz,:); 
#ifdef IMPULSE
          Fplane(:,:,ix)=F(iy-2:iy+2,ix,iz,:);
#endif
        END DO
        DO ix=0,nx
            VVm2=VVd(ix+1,izd(iz)+1,1:6,im2); VVm1=VVd(ix+1,izd(iz)+1,1:6,im1); VV0=VVd(ix+1,izd(iz)+1,1:6,i0); 
            VV1=VVd(ix+1,izd(iz)+1,1:6,i1);   VV2=VVd(ix+1,izd(iz)+1,1:6,i2);   
            DD0_6=DD(d0,6); DD1_6=DD(d1,6);
            rhsu=-ialfa(ix)*DD(d0,1)-DD(d1,4)-ibeta(iz)*DD0_6
            rhsv=-ialfa(ix)*DD(d0,4)-DD(d1,2)-ibeta(iz)*DD(d0,5)
            rhsw=-ialfa(ix)*DD0_6-DD(d1,5)-ibeta(iz)*DD(d0,3)
            expl=(ialfa(ix)*(ialfa(ix)*DD(d1,1)+DD(d2,4)+ibeta(iz)*DD1_6)+&
                  ibeta(iz)*(ialfa(ix)*DD1_6+DD(d2,5)+ibeta(iz)*DD(d1,3))-k2(ix,iz)*rhsv &
#ifdef IMPULSE
                  -k2(ix,iz)*D0(Fplane,2)-ialfa(ix)*D1(Fplane,1)-ibeta(iz)*D1(Fplane,3))
#else
                 )
#endif
            timescheme(newrhs(iy,ix,iz)%D2v, oldrhs(iy,ix,iz)%D2v, D2(Vplane,2)-k2(ix,iz)*D0(Vplane,2),
                       sum(OS(iy,-2:2)*Vplane(-2:2,2,ix)),expl); !(D2v)
            IF (ix==0 .AND. iz==0) THEN
              expl=(dcmplx(dreal(rhsu)+meanpx,dreal(rhsw)+meanpz) &
#ifdef IMPULSE
                    +rD0(Fplane,1,3))       
#else
                   )
#endif
              timescheme(newrhs(iy,0,0)%eta,oldrhs(iy,0,0)%eta,rD0(Vplane,1,3),ni*rD2(Vplane,1,3),expl) !(Ubar, Wbar)
            ELSE
              expl=(ibeta(iz)*rhsu-ialfa(ix)*rhsw &
#ifdef IMPULSE
                    +ibeta(iz)*D0(Fplane,1)-ialfa(ix)*D0(Fplane,3))
#else 
                   )
#endif
              timescheme(newrhs(iy,ix,iz)%eta, oldrhs(iy,ix,iz)%eta,ibeta(iz)*D0(Vplane,1)-ialfa(ix)*D0(Vplane,3),
                              sum(SQ(iy,-2:2)*[ibeta(iz)*Vplane(-2:2,1,ix)-ialfa(ix)*Vplane(-2:2,3,ix)]),expl) !(eta)
            END IF
        END DO
        END DO
      END IF
      END IF
      IF (iy-2>=1) THEN
        DO CONCURRENT (ix=0:nx, iz=-nz:nz) 
          V(iy-2,ix,iz,1) = newrhs(iy-2,ix,iz)%eta; V(iy-2,ix,iz,2) = newrhs(iy-2,ix,iz)%d2v; 
        END DO
      END IF      
    END DO
  END SUBROUTINE buildrhs

  !--------------------------------------------------------------!
  !-------------------- read_restart_file -----------------------!
  SUBROUTINE read_restart_file()
    OPEN(UNIT=100,FILE="Dati.cart.out",access="stream",action="read")
    READ(100) V
    CLOSE(100)
  END SUBROUTINE read_restart_file

  !--------------------------------------------------------------!
  !-------------------- save_restart_file -----------------------!
  SUBROUTINE save_restart_file()
    OPEN(UNIT=100,FILE="Dati.cart.out",access="stream",status="replace",action="write")
    WRITE(100,POS=1) V
    CLOSE(100)
  END SUBROUTINE save_restart_file

  !--------------------------------------------------------------!
  !------------------------- outstats ---------------------------!
  SUBROUTINE outstats()
   WRITE(*,"(F6.4,3X,4(F11.8,3X),4(F9.6,3X),2(F5.3,3X))") &
            time,sum(d140(-2:2)*dreal(V(-1:3,0,0,1))),-sum(d14n(-2:2)*dreal(V(ny-3:ny+1,0,0,1))),&
            sum(d140(-2:2)*dreal(V(-1:3,0,0,3))),-sum(d14n(-2:2)*dreal(V(ny-3:ny+1,0,0,3))),&
            yintegr(dreal(V(:,0,0,1))),meanpx+corrpx,yintegr(dreal(V(:,0,0,3))),meanpz+corrpz,&
            cfl*deltat,deltat
   IF (cflmax>0)  deltat=cflmax/cfl; cfl=0
   !Save Dati.cart.out
   IF ( (FLOOR((time+0.5*deltat)/dt_save) > FLOOR((time-0.5*deltat)/dt_save)) .AND. (time>0) ) THEN
     WRITE(*,*) "Writing Dati.cart.out at time ", time
     CALL save_restart_file()
   END IF
#ifdef IMPULSE
    !Save Impulse Response
    IF ( (FLOOR((time+0.5*deltat)/dt_field) > FLOOR((time-0.5*deltat)/dt_field)) .AND. (time>0) ) THEN
      WRITE(*,*) "Writing impulse response at time ", time
#ifdef fx
      OPEN(UNIT=300,FILE="Hx.bin",access="stream",status="replace",action="write")
      WRITE(300,POS=1) Hx
      CLOSE(300)
#endif
#ifdef fy
      OPEN(UNIT=300,FILE="Hy.bin",access="stream",status="replace",action="write")
      WRITE(300,POS=1) Hy
      CLOSE(300)
#endif
#ifdef fz
      OPEN(UNIT=300,FILE="Hz.bin",access="stream",status="replace",action="write")
      WRITE(300,POS=1) Hz
      CLOSE(300)
#endif
    END IF
#endif
  END SUBROUTINE outstats


END MODULE dnsdata
