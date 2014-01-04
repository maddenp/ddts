program tr

  ! based on Pacheco's 'Parallel Programming With MPI' chapter 4

  use mpi

  implicit none

  integer :: i        ! loop variable
  integer :: ln       ! number of trapezoids for this task
  integer :: me       ! my mpi rank
  integer :: mpistat  ! mpi status
  integer :: n=0      ! number of trapezoids
  integer :: p        ! number of mpi tasks
  integer :: source   ! mpi task sending integral
  integer :: status   ! io status
  real    :: a=0,b=0  ! left and right interval endpoints
  real    :: h        ! trapezoid base width
  real    :: integral ! integral over my integral
  real    :: la,lb    ! local left and right interval endpoints
  real    :: total    ! total integral
  real    :: x        ! generic real temp

  character(len=5),parameter :: infile='tr.nl'
  character(len=4),parameter :: outfile1='out1'
  character(len=4),parameter :: outfile2='out2'
  integer,parameter          :: lun=77

  namelist /config/ a,b,n
  call mpi_init(mpistat)
  call mpi_comm_rank(mpi_comm_world,me,mpistat)
  call mpi_comm_size(mpi_comm_world,p,mpistat)
  if (me.eq.0) then
    open (lun,file=infile,status='old',iostat=status)
    if (status.ne.0) then
      write (*,'(a,a)') 'Error opening config file ',infile
      stop
    end if
    read (lun,nml=config)
    close (lun)
  end if
  call mpi_bcast(a,1,mpi_real,   0,mpi_comm_world,mpistat)
  call mpi_bcast(b,1,mpi_real,   0,mpi_comm_world,mpistat)
  call mpi_bcast(n,1,mpi_integer,0,mpi_comm_world,mpistat)
  if (n.lt.1) then
    write (*,'(a)') "Configuration parameter 'n' must be > 0"
    call mpi_finalize(mpistat)
    stop
  end if
  h=(b-a)/n;
  ln=n/p;
  la=a+me*ln*h
  lb=la+ln*h
  integral=trap(la,lb,ln,h)
  if (me.eq.0) then
    total=integral
    do source=1,p-1
      call mpi_recv(integral,1,mpi_real,source,0,mpi_comm_world,mpi_status_ignore,mpistat)
      total=total+integral
    end do
  else
    call mpi_send(integral,1,mpi_real,0,0,mpi_comm_world,mpistat)
  end if
  if (me.eq.0) then
    ! output file containing integral
    open (lun,file=outfile1,status='new',iostat=status)
    if (status.ne.0) then
      write (*,'(a,a)') 'Error opening output file ',outfile1
      stop
    end if
    write (lun,'(f4.2)') total
    close (lun)
    ! output file containing a constant
    open (lun,file=outfile2,status='new',iostat=status)
    if (status.ne.0) then
      write (*,'(a,a)') 'Error opening output file ',outfile1
      stop
    end if
    write (lun,'(i0)') 88
    close (lun)
  end if
  call mpi_finalize(mpistat)
  write (*,'(a)') 'SUCCESS'

contains

  real function trap(la,lb,ln,h)

    integer,intent(in) :: ln
    integer            :: i
    real,intent(in)    :: la,lb,h
    real               :: integral,x

    integral=(f(la)+f(lb))/2.0
    x=la
    do i=1,ln-1
      x=x+h
      integral=integral+f(x)
    end do
    integral=integral*h
    trap=integral

  end function trap

  real function f(x)

    real,intent(in)::x

    f=sin(x)

  end function f

end program tr
