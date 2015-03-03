#!/usr/bin/env bash
set -e
set -x
# Redirect stdout ( > ) into a named pipe ( >() ) running "tee"
exec > >(tee $(date +%F)_$(date +"%I-%M-%S")_spreads_deploy_log.txt)
exec 2>&1
SCRIPTPATH="$( cd "$( echo "${BASH_SOURCE[0]%/*}" )" && pwd )"

echo "Do you want to install for capturing only[1], server only [2] or full [3]:"
read mode

echo "Please set the number of cores for the c-compiler:"
read j

## aptitude
sh scripts/aptitude.sh $mode

##install latest leptonica
sh scripts/leptonica.sh $mode $j
exit 0
## install tesseract from git
command -v tesseract >/dev/null 2>&1 || {
if [[ ! -d tesseract-ocr ]]
then
git clone https://code.google.com/p/tesseract-ocr/
fi
cd tesseract-ocr/tessdata
## check if the trainingfiles are there and if not add them from git
if [[ ! -f deu.traineddata ]]
then
git clone https://code.google.com/p/tesseract-ocr.tessdata/ tessdata
cp tessdata/* .
sudo rm -r tessdata
cd ..
else 
cd ..
fi
git pull
./autogen.sh
./configure
make -j
sudo make install
make -j training
sudo make training-install
sudo make install LANGS=
cd ..
}
##Install jbig2enc
command -v jbig2 >/dev/null 2>&1 || {
git clone https://github.com/agl/jbig2enc
cd jbig2enc
./autogen.sh
./configure
make -j
sudo make install
cd ..
}

##next install pdfbeads
command -v pdfbeads >/dev/null 2>&1 || {
git clone https://github.com/ifad/pdfbeads
cd pdfbeads
gem build pdfbeads.gemspec 
sudo gem install pdfbeads-1.0.11.gem
cd ..
}
##next install latest djvubind
command -v djvubind >/dev/null 2>&1 || {
git clone https://github.com/strider1551/djvubind
cd djvubind
sudo ./setup.py install
cd ..
}

## Install Scantailor
command -v scantailor-cli >/dev/null 2>&1 || {
wget -O scantailor-enhanced-20140214.tar.bz2 http://downloads.sourceforge.net/project/scantailor/scantailor-devel/enhanced/scantailor-enhanced-20140214.tar.bz2
tar xvjf scantailor-enhanced-20140214.tar.bz2
cd scantailor-enhanced
cmake .
make -j
sudo make install
}

##create and open a new file - not necessary I think
if grep -q /usr/local/lib/chdkptp/ "/etc/ld.so.conf.d/spreads.conf"
then
sudo sh -c "echo '/usr/local/lib/chdkptp/' >> /etc/ld.so.conf.d/spreads.conf"
fi

## Add udev rule for hidtrigger
if grep -q 'ACTION=="add", SUBSYSTEM=="usb", MODE:="666"' "/etc/udev/rules.d/99-usb.rules"
then
sudo sh -c "echo 'ACTION=="add", SUBSYSTEM=="usb", MODE:="666"' > /etc/udev/rules.d/99-usb.rules"
sed -i -e 's/KERNEL\!="eth\*|/KERNEL\!="/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
fi
##reload the system-wide libraries paths
sudo ldconfig

##now install libyaml
if [[ ! -f /usr/local/lib/libyaml-0.so.2.0.3 ]]
then
wget http://pyyaml.org/download/libyaml/yaml-0.1.5.tar.gz
tar xvf yaml-0.1.5.tar.gz
cd yaml-0.1.5
./configure
make -j
sudo make install
cd ..
fi

##finally install spreads in an virtualenv, create a new one
virtualenv ~/.spreads
source ~/.spreads/bin/activate

pip install pycparser 
pip install cffi 
pip install jpegtran-cffi
pip install --upgrade --pre pyusb
pip install --install-option='--no-luajit' lupa

##enable spreads GUI packages by installing PySide and fixing symbolic link problem
sudo ln -s /usr/lib/python2.7/dist-packages/PySide ~/.spreads/lib/python2.7/site-packages/PySide

##add current user to staff group  (the word ´username´ must be replaced by the current username)
sudo adduser $(whoami) staff
##ow add the lua env variable to the global path in order that the chdkptp command will work
#!#add check!
echo "export CHDKPTP_DIR=/usr/local/lib/chdkptp" >> ~/.bashrc 
echo "export LUA_PATH="$CHDKPTP_DIR/lua/?.lua"" >> ~/.bashrc 
echo "source ~/.spreads/bin/activate" >> ~/.bashrc 
## type 
source ~/.bashrc
## fix errors with turbojpeg - need paths for armhf
#x86_64
sudo ln -s /usr/lib/x86_64-linux-gnu/libturbojpeg.so.0.0.0 /usr/lib/x86_64-linux-gnu/libturbojpeg.so
#gnueabihf
#sudo ln -s /usr/lib/arm-linux-gnueabihf/libturbojpeg.so.0.0.0 /usr/lib/arm-linux-gnueabihf/libturbojpeg.so
##we need some more python modules for the spread web plugin
pip install Flask
pip install tornado
pip install requests
pip install waitress
pip install zipstream
pip install Wand
pip install Flask-Compress
##now install spreads
wget http://buildbot.diybookscanner.org/nightly/spreads-latest.tar.gz
tar xvf spreads-latest.tar.gz
cd spreads-*
pip install .
pip install -e ".[web]"
pip install -e ".[hidtrigger]"
pip install chdkptp.py
cd ..
##Kill gphoto.
pkill -9 gphoto2

echo Now run spread configure
echo I suggest you activate: autorotate, djvubind, hidtrigger, pdfbeads, scantailor, tesseract, web
echo Lateron, after a reboot, start spreads via \"spread web\" and open any browser with "[YOURIP]:5000"
echo If you dont want to disable gphoto2 permanently I suggest you type in "pkill -9 gphoto2" before you power on your cameras.
exit 0
