@echo off

echo.
echo Benchmark a corpus, stored in directory "%1", using various Zippers
echo.

if "%1" == "" goto instr
if not exist "%1" echo Directory "%1" doesn't exist - stopping benchmark.
if not exist "%1" goto instr

del bench_%1_*.zip

cd %1

if not "%2" == "full" goto skip

rem   ### LZW
zipada      ../bench_%1_shrink    *
rem   ### Reduce (LZ & Markov)
zipada -er4 ../bench_%1_reduce_4  *
rem   ### Deflate
zip    -6   ../bench_%1_iz_6      *
zip    -9   ../bench_%1_iz_9      *
kzip        ../bench_%1_kzip      *
7z a -tzip -mm=deflate -mx5  ../bench_%1_7zip_defl_5 *
7z a -tzip -mm=deflate -mfb=258 -mpass=15 -mmc=10000 ../bench_%1_7zip_deflate *
advzip -a -4 ../bench_%1_zopfli.zip *
rem   ### BZip2
zip -9 -Z bzip2 ../bench_%1_bzip2_9 *
rem   ### LZMA
7z a -tzip -mm=LZMA:a=2:d=25:mf=bt3:fb=255:lc=7 ../bench_%1_7zip_lzma *

:skip
if exist Zip.Compress.Deflate.zcd del Zip.Compress.Deflate.zcd
zipada -edf ../bench_%1_deflate_f *
if exist Zip.Compress.Deflate.zcd del Zip.Compress.Deflate.zcd
zipada -ed1 ../bench_%1_deflate_1 *
if exist Zip.Compress.Deflate.zcd copy Zip.Compress.Deflate.zcd ..\Zip.Compress.Deflate_1_%1.zcd
zipada -ed2 ../bench_%1_deflate_2 *
if exist Zip.Compress.Deflate.zcd copy Zip.Compress.Deflate.zcd ..\Zip.Compress.Deflate_2_%1.zcd
zipada -ed3 ../bench_%1_deflate_3 *
if exist Zip.Compress.Deflate.zcd copy Zip.Compress.Deflate.zcd ..\Zip.Compress.Deflate_3_%1.zcd
if exist Zip.Compress.Deflate.zcd del Zip.Compress.Deflate.zcd

cd ..

rem Wrapping it all - update archive with all archives

zip all_bench_%1 bench_%1_*.zip
del bench_%1_*.zip

goto fin

:instr
echo Usage
echo   bench directory_name [full]
echo.
echo When "full", redo all (including compression methods already tested)
echo Will produce bench_directory_name_... .zip
echo.
echo See benchs.cmd for a set of benchmarks
echo.
pause
:fin