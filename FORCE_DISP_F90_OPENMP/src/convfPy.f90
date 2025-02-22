
!   FUNCTION CONVMPY
!
!   Fortran version of convolution to be called from python
!   Force version
!
! Convolution and output using output() routine
! All computations done in double float format(64bits)
!
!******************************************************************************

! number of elementary source, 6 for moment, 3 for forces
#define NSTYPE 3

! Input
! id: unique id for this computation used for all input/output name files
! ics: source type
! t0, t1: time co,nstant for the source type
! icc: output unit, disp, vel or acc
! Output
! sx, sy, sz: seismograms along the three components
! nsx, ntx: dimension for sx
! n1y, n2y: dimension for sy
! n1z, n2z: dimension for sz
subroutine force_conv(id,ics, t0, t1, icc, sx,sy,sz,nsx,ntx,n1y,n2y,n1z,n2z)

   use parameter
   use fsourcem
#if defined(_OPENMP)
   use omp_lib
#endif
   implicit none

!f2py intent(in) ics,t0,t1,icc
!f2py intent(in,out,overwrite,c) sx
!f2py intent(in,out,overwrite,c) sy
!f2py intent(in,out,overwrite,c) sz
!f2py integer intent(hide),depend(sx) :: nsx=shape(sx,0), ntx=shape(sx,1)
!f2py integer intent(hide),depend(sy) :: n1y=shape(sy,0), n2y=shape(sy,1)
!f2py integer intent(hide),depend(sz) :: n1z=shape(sz,0), n2z=shape(sz,1)


   integer :: nt,nstat,nsx,ntx,n1y,n2y,n1z,n2z
   real(kind=8) :: sx(ntx,nsx),sy(n2y,n1y),sz(n2z,n1z)

   integer ntp, nrtp, icc, ics, ic, base

   character header*50, sourcefile*20, statfile*20, chan(3)*2,arg*50
   integer :: id
   integer :: jf, ir, is, it, nc, ns, nr, nfreq, ikmax, mm, io, indexin
   real(kind=8)    ::  tl, xl, uconv, hh, zsc, dfreq, freq, aw, ck, xmm, xref, yref, &
                       lat, long, t0, t1, pas, dt0, rfsou, stime
   complex(kind=8) ::  omega, uxf(NSTYPE), uyf(NSTYPE), uzf(NSTYPE), deriv, us, uux, uuy, uuz, cc, freqs
   logical                   :: latlon,freesurface
   integer, allocatable      :: iwk(:), isc(:), rindex(:), sindex(:)
   real(kind=8), allocatable :: hc(:), vp(:), vs(:), rho(:), delay(:), xr(:), yr(:), zr(:), a(:, :), qp(:), qs(:), &
                                disp(:), xs(:), ys(:), zs(:), amp(:)
   complex(kind=8), allocatable :: ux(:, :), uy(:, :), uz(:, :), fsou(:)

   namelist/input/nc, nfreq, tl, aw, nr, ns, xl, ikmax, latlon, freesurface, sourcefile, statfile

   dt0 = 0.
   chan(1) = 'X'
   chan(2) = 'Y'
   chan(3) = 'Z'

!
! header
!
   if (id<0) then
     header='axi'
   else if (id<10) then
     write(header,"('axi_',I1)") id
   else if (id<100) then
     write(header,"('axi_',I2)") id
   else
     write(header,"('axi_',I3)") id
   endif

! test wether we want only the source time function
   stime = 1.d0
   if (ics>=10) then
   write(0,*) 'do not convolve, output only source time function',ics
     ics=ics-10
     stime = 0.d0
   endif


! read binary results from axitra
! We assume here that record length is given in byte.
! For intel compiler, it means using "assume byterecl" option
! record length is 6 x (complex double precision) = 6 x 2 x 8 bytes
   open (12, access='direct', recl=NSTYPE*2*8, form='unformatted', file=trim(header)//'.res')


! read input file to axitra
   open (10, form='formatted', file=trim(header)//'.data')
   read (10, input)
! count number of layer
   nc=0
   do while(.true.)
     read(10,*,end=91)
     nc=nc+1
   end do
91 rewind(10)
   read (10, input)

   open (13, form='formatted',file=sourcefile)
   open (14, form='formatted', file=statfile)
! count number of sources
   ns=0
   do while(.true.)
     read(13,*,end=92)
     ns=ns+1
   end do
92 rewind(13)
! count number of receiver
   nr=0
   do while(.true.)
     read(14,*,end=93)
     nr=nr+1
    end do
93 rewind(14)

! allocate space knowing number of sources, receivers and layers
   allocate (hc(nc), vp(nc), vs(nc), qp(nc), qs(nc), rho(nc))
   allocate (delay(ns), amp(ns))
   allocate (xs(ns), ys(ns), zs(ns), isc(ns), a(NSTYPE, ns))
   allocate (xr(nr), yr(nr), zr(nr), rindex(nr),sindex(ns))

! other input files
   open (15, form='formatted', file=trim(header)//'.hist')

! + +++++++++++
! read source function type from input args with t0,t1
! + +++++++++++
   icc = icc - 1

!++++++++++++
!                 medium, source and station
!++++++++++++
   do ic = 1, nc
      read (10, *) hc(ic), vp(ic), vs(ic), rho(ic), qp(ic), qs(ic)
   enddo
   close (10)

   do is = 1, ns
      read (13, *) sindex(is), xs(is), ys(is), zs(is)
   enddo
   ! sort by increasing depth to make sure that
   ! it read data in the correct ordering
   call sortByDepth(sindex,xs,ys,zs,ns)
   do is = 1, ns
      indexin = -1
      rewind (15)
      do while (indexin .ne. sindex(is))
         read (15, *) indexin, a(1,is), a(2,is), a(3,is), amp(is), delay(is)
      enddo
      delay(is) = delay(is) + dt0
   enddo

   do ir = 1, nr
      read (14, *) rindex(ir), xr(ir), yr(ir), zr(ir)
! reference: x = north; y = east
   enddo
! sort by increasing depth because Green's functions are sorted by receiver increasing depth
   call sortByDepth(rindex,xr,yr,zr,nr)
!
   if (latlon) then
      call ll2km(xr, yr, nr, xs, ys, ns)
   endif

!++++++++++++
!        Parametres sources
!++++++++++++
!     conversion depth -> thickness
   if (hc(1) .eq. 0.) then
      do ic = 1, nc - 1
         hc(ic) = hc(ic + 1) - hc(ic)
      enddo
   endif

   do is = 1, ns
      hh = 0.
      isc(is) = 1
      zsc = zs(is)
      do ic = 1, nc - 1
         hh = hc(ic)
         if (zsc .gt. hh) then
            zsc = zsc - hh
            isc(is) = ic + 1
         else
            exit
         endif
      enddo

      a(1,is)=a(1,is)*amp(is)
      a(2,is)=a(2,is)*amp(is)
      a(3,is)=a(3,is)*amp(is)
   enddo


!++++++++++++
!        Lecture fonctions de transfert
!++++++++++++
   xmm = log(real(nfreq))/log(2.)
   mm = int(xmm) + 1
   if (xmm-mm+1 >0) mm=mm+1

   nt = 2**mm
   allocate (iwk(nt))
   allocate (ux(nt, nr), uy(nt, nr), uz(nt, nr))
   ux = 0.d0
   uy = 0.d0
   uz = 0.d0
   dfreq = 1./tl
   pas = tl/nt
   aw = -pi*aw/tl

! if source time function is supplied, read it
   if (ics .eq. 3) then
     open (16, form='formatted', file=trim(header)//'.sou')
     allocate(fsou(nt))
     fsou=0.d0
     do it=1,nt
       read(16,*, end=1960) rfsou
       ck = float(it - 1)/nt
       cc = exp(aw*tl*ck)
       fsou(it)=rfsou*cc
     enddo
     ! direct FFT normalization
     ! Since the same call is used for inverse transform
     ! needs conjugate
     call fft2cd(fsou, mm, iwk)
     fsou=conjg(fsou)
1960 continue
   endif



! loop over frequencies
   open (10, form='formatted', file=trim(header)//'.head')
   do jf = 1, nfreq
      freq = float(jf - 1)/tl
      omega = cmplx(pi2*freq, aw)
      deriv = (ai*omega)**icc

      read (10, *, end=2000)
      if (ics == 3) then
        freqs=fsou(jf)
      else
        freqs=fsource(ics, t0, omega, t1, pas)
      endif

      do is = 1, ns ! loop over source
         us = freqs*deriv*exp(-ai*omega*delay(is))

         do ir = 1, nr ! loop over receiver
            base = (ir - 1)*3 + (is - 1)*3*nr + (jf - 1)*3*nr*ns
            read (12, rec=base + 1, err=2000) (uxf(it), it=1, NSTYPE)
            read (12, rec=base + 2, err=2000) (uyf(it), it=1, NSTYPE)
            read (12, rec=base + 3, err=2000) (uzf(it), it=1, NSTYPE)
            uux = 0.
            uuy = 0.
            uuz = 0.
            do it = 1, NSTYPE
               uux = uux + (uxf(it)*stime + (1.d0-stime))*a(it, is)
               uuy = uuy + (uyf(it)*stime + (1.d0-stime))*a(it, is)
               uuz = uuz + (uzf(it)*stime + (1.d0-stime))*a(it, is)
			   if (isnan(real(uux)) .or. isnan(real(uuy)) .or. isnan(real(uuz))) write(0,*) 'real part uux,uuy or uuz is NaN'
               if (isnan(imag(uux)) .or. isnan(imag(uuy)) .or. isnan(imag(uuz))) write(0,*) 'imag part uux,uuy or uuz is NaN'
            enddo
            ux(jf, ir) = ux(jf, ir) + uux*us
            uy(jf, ir) = uy(jf, ir) + uuy*us
            uz(jf, ir) = uz(jf, ir) + uuz*us
         enddo !fin boucle recepteur
      enddo !fin boucle source
   enddo
2000 continue
   if (jf < nfreq) then
      nfreq = jf - 1
   endif

!++++++++++++
!                Calcul des sismogrammes
!++++++++++++
!$OMP PARALLEL DEFAULT(FIRSTPRIVATE) &
!$OMP SHARED(ux,uy,uz,nr,mm,rindex,sx,sy,sz,nt,nfreq,tl,aw)
#if defined(_OPENMP)
   if (omp_get_thread_num()==1) then
       write(0,*) 'running openMp on ',omp_get_num_threads(),' threads'
   endif
#endif

!$OMP DO ORDERED,SCHEDULE(DYNAMIC)
   do ir = 1, nr

!                on complete le spectre pour les hautes frequences
!               avec inversion du signe de la partie imaginaire pour
!               la FFT inverse qui n existe pas avec fft2cd
      do jf = nt + 2 - nfreq, nt
         ux(jf, ir) = conjg(ux(nt + 2 - jf, ir))
         uy(jf, ir) = conjg(uy(nt + 2 - jf, ir))
         uz(jf, ir) = conjg(uz(nt + 2 - jf, ir))
      enddo

      call fft2cd(ux(1, ir), mm, iwk)
      call fft2cd(uy(1, ir), mm, iwk)
      call fft2cd(uz(1, ir), mm, iwk)

      do it = 1, nt
         ck = float(it - 1)/nt
         cc = exp(-aw*tl*ck)/nt
         sx(it,rindex(ir)+1) = (ux(it, ir)*cc)
         sy(it,rindex(ir)+1) = (uy(it, ir)*cc)
         sz(it,rindex(ir)+1) = (uz(it, ir)*cc)
      enddo

   enddo
!$OMP END DO
!$OMP END PARALLEL
   close(10)
   close(12)
   close(13)
   close(14)
   close(15)
   close(16)

   deallocate (hc, vp, vs, qp, qs, rho)
   deallocate (xs, ys, zs, isc, amp, delay)
   deallocate (xr, yr, zr, rindex,sindex)
   if (ics==3) deallocate (fsou)
   deallocate (iwk)
   deallocate (ux, uy, uz)

   
end

subroutine sortByDepth(rindex,xr,yr,zr,nr)
  implicit none
  real(kind=8) :: xr(*),yr(*),zr(*),tmp
  integer      :: nr,ir,jr,itmp,rindex(*)
!++++++++++++
!         sort stations according to increasing depth
!         we do that whatever the ordering was in the station file
!++++++++++++
   do ir = 1, nr - 1
      do jr = ir, nr
         if (zr(ir) .gt. zr(jr)) then
            tmp = xr(ir)
            xr(ir) = xr(jr)
            xr(jr) = tmp
            tmp = yr(ir)
            yr(ir) = yr(jr)
            yr(jr) = tmp
            tmp = zr(ir)
            zr(ir) = zr(jr)
            zr(jr) = tmp
            itmp = rindex(ir)
            rindex(ir) = rindex(jr)
            rindex(jr) = itmp
         endif
      enddo
   enddo
end subroutine
