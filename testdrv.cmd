cmd.exe /C copydrv.cmd

sc stop cfixkr_testfbt_km_wrk
sc stop cfixkr_testfbt_km_retail
sc stop jpkfar
sc stop jpkfaw

rem TEST FREE BUILDS!

pushd %SystemDrive%\drv\i386
cfix32 -b -u -kern testfbt_km_wrk.sys
cfix32 -f -b -u testkfbt.dll
popd
