#!/bin/zsh
# Renders every sample of the study with every candidate and measures them: the real samples against
# main, the overexposed ones against the unclipped original's render. Run from the repository root,
# with REDLAMP_CLI and HIGHLIGHTS_OUT set as candidates.sh says.
F=$PWD/tests/fixtures
here=${0:A:h}
python=${PYTHON:-python3}
cd $HIGHLIGHTS_OUT
mkdir -p logs
typeset -A raws stops
raws=(z8 $F/cameras/Nikon_Z-8.NEF pixel4a $F/raw/PXL_20201121_100251397.dng g9 $F/shoots/scenes/Panasonic_DC-G9_P1000475.RW2
      om1 $F/cameras/OM-System_OM-1-Mark-II.orf a7iv $F/cameras/Sony_ILCE-7M4.ARW s5 $F/cameras/Panasonic_DC-S5M2.RW2
      dsc0009 $F/raw/_DSC0009.ARW xt5-over2 $F/cameras/Fujifilm_X-T5.RAF r6-over2 $F/raw/Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3
      xt3-over2 $F/raw/AFXT2720.RAF)
stops=(xt5-over2 2 r6-over2 2 xt3-over2 2)
for sample in ${=SAMPLES:-xt3-over2 z8 pixel4a g9 om1 a7iv s5 dsc0009 xt5-over2 r6-over2}; do
  raw=${raws[$sample]}; s=${stops[$sample]:-0}
  CANDIDATES="main a b c d ef e8" $here/candidates.sh $raw $sample $s > logs/$sample.log 2>&1
  crop=0,0,1,1; [ $sample = z8 ] && crop=0,0,1,0.42
  if [ $s != 0 ]; then
    CANDIDATES=main $here/candidates.sh $raw $sample-truth 0 >> logs/$sample.log 2>&1
    CAM08_OVEREXPOSE=$s $python $here/compare.py $raw renders/$sample $crop renders/$sample-truth main > logs/$sample.txt 2>&1
    CAM08_OVEREXPOSE=$s $python $here/truth.py $raw $sample > logs/$sample.truth.txt 2>&1
  else
    $python $here/compare.py $raw renders/$sample $crop > logs/$sample.txt 2>&1
  fi
  echo "done $sample $(date +%H:%M:%S)"
done
echo all done
