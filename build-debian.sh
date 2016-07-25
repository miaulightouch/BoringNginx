#!/bin/bash
set -e
shopt -s extglob
if [ "$(id -u)" -eq 0 ]; then echo -e "This script is not intended to be run as root.\nExiting." && exit 1; fi


# ngxversion "nginx version"
function ngxversion() {
    echo ""
    echo "Nginx version: $1"
    string="@($supver)"
    case $1 in
        $string ) echo "It's Supported version.";;
        *) echo "Unknown version, try default settings.";;
    esac
    echo ""
}


# Default settings
rpath="$(cd $(dirname $0) && pwd)" # Run path
bdir="/tmp/patchednginx-$RANDOM" # Set build directory
ngxver="1.10.1" # Default nginx version

supver="1.10.0|1.11.0|1.10.1|1.11.1|1.11.2" # Supported version

opensslver=1.0.2h                                                # OpenSSL version
libresslver=2.3.6                                                # LibreSSL version
chacha20=openssl__chacha20_poly1305_draft_and_rfc_ossl102g.patch # CF ChaCha20_Poly1305 patch
spdy=nginx_1_9_15_http2_spdy.patch                               # updated CF SPDY patch
rules=rules.0.patch                                              # DEB rules patch


# Handle arguments passed to the script. Currently only accepts the flag to
# include passenger at compile time,but I might add a help section or more options soon.
while [ "$#" -gt 0 ]
do
    case $1 in
        --hardening|-hardening|hardening) HARDENING="1"; shift;;
        --passenger|-passenger|passenger) PASSENGER="1"; echo ""; echo "Phusion Passenger module enabled."; shift;;
        --boringssl|-boringssl|boringssl) BORINGSSL="1"; shift;;
        --openssl|-openssl|openssl) OPENSSL="1"; shift;;
        --libressl|-libressl|libressl) LIBRESSL="1"; shift;;
        1.*) ngxver=$1; shift;;
        *)
            echo "Invalid argument: $1"
            echo ""
            echo "Usage: $0 [Option]..."
            echo ""
            echo "--boringssl    Use BoringSSL source"
            echo "--libressl     Use LibreSSL source"
            echo "--openssl      Use OpenSSL source with ChaCha20_Poly1305 patch"
            echo ""
            echo "--passenger    Build with passenger module"
            echo ""
            echo "--hardening    Enable full relro"
            exit 10
        ;;
    esac
done
ngxversion $ngxver
[ ! $BORINGSSL -o ! $LIBRESSL ] && OPENSSL="1" # Use OpenSSL if not set


# Prompt our user before we start removing stuff
CONFIRMED=0
echo -e "This script will remove any versions of Nginx you installed using yum, and\nreplace any version of Nginx built with a previous version of this script."
while true
do
    echo ""
    read -p "Do you wish to continue? (Y/N) " answer
    case $answer in
        [yY]* ) CONFIRMED=1; break;;
        * ) echo "Please enter 'Y' to continue or use ^C to exit.";;
    esac
done
if [ "$CONFIRMED" -eq 0 ]; then echo -e "Something went wrong.\nExiting." && exit 1; fi


# Install deps
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true
sudo apt -y install build-essential libpcre3-dev wget zlib1g-dev libcurl4-openssl-dev debhelper libgd2-xpm-dev libgeoip-dev libperl-dev libssl-dev libxslt1-dev


# Prepare source
mkdir "$bdir" && mkdir -p "$rpath/source" && cd "$rpath/source"
[ $(($(expr $ngxver : '..\([0-9]*\).*')%2)) -eq 1 ] && Mainline=mainline/
[ ! -e nginx_$ngxver.orig.tar.gz ] && wget -t 3 "http://nginx.org/packages/${Mainline}debian/pool/nginx/n/nginx/nginx_$ngxver.orig.tar.gz"
[ ! -e nginx_$ngxver-1~jessie.debian.tar.xz ] && wget -t 3 "http://nginx.org/packages/${Mainline}debian/pool/nginx/n/nginx/nginx_$ngxver-1~jessie.debian.tar.xz"
[ ! -e nginx_$ngxver-1~jessie.dsc ] && wget -t 3 "http://nginx.org/packages/${Mainline}debian/pool/nginx/n/nginx/nginx_$ngxver-1~jessie.dsc"
dpkg-source -x nginx_$ngxver-1~jessie.dsc "${bdir}/source"

patch -p1 -d "${bdir}/source" < "${rpath}/patches/${spdy}"


# Prepare SSL
if [ $OPENSSL ]
then
    mkdir -p "${rpath}/openssl" && cd "${rpath}/openssl"
    until [ "$VALID" == "1" ]; do
        [ $WRONG ] && wget -t 3 "https://www.openssl.org/source/openssl-${opensslver}.tar.gz"
        wget -t 3 -c "https://www.openssl.org/source/openssl-${opensslver}.tar.gz.sha256"
        sha256sum openssl-${opensslver}.tar.gz | grep $(cat openssl-${opensslver}.tar.gz.sha256) && VALID=1 || WRONG=1
    done

    tar xf "${rpath}/openssl/openssl-${opensslver}.tar.gz" -C "${bdir}/source"
    patch -d "${bdir}/source/openssl-${opensslver}" -p1 < "${rpath}/patches/$chacha20"
    touch "${bdir}/source/openssl-${opensslver}/Makefile"

    SSLPACK="openssl-${opensslver}"
fi

if [ $BORINGSSL ]
then
    sudo apt -y install cmake git golang

    if [ -e "${rpath}/boringssl" ]
    then
        cd "${rpath}/boringssl"
        git fetch && git pull
    else
        git clone "https://boringssl.googlesource.com/boringssl" "${rpath}/boringssl"
    fi

    cp -r "${rpath}/boringssl" "${bdir}/source"
    mkdir -p "${bdir}/source/boringssl/build" && cd "${bdir}/source/boringssl/build"
    cmake ../ && make
    mkdir -p "${bdir}/source/boringssl/.openssl/lib"
    cd "${bdir}/source/boringssl/.openssl" && ln -s ../include
    cd "${bdir}/source/boringssl" && cp "build/crypto/libcrypto.a" "build/ssl/libssl.a" ".openssl/lib"
    patch -p1 -d "${bdir}/source" < "${rpath}/patches/boring.patch"

    SSLPACK="boringssl"
fi

if [ $LIBRESSL ]
then
    mkdir -p "${rpath}/libressl" && cd "${rpath}/libressl"
    until [ "$VALID" == "1" ]; do
        [ $WRONG ] && wget -t 3 "http://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${libresslver}.tar.gz"
        wget -t 3 -c "http://ftp.openbsd.org/pub/OpenBSD/LibreSSL/SHA256" 
        grep libressl-${libresslver}.tar.gz SHA256 | sha256sum -c && VALID=1 || WRONG=1
    done
    tar xf "${rpath}/libressl/libressl-${libresslver}.tar.gz" -C "${bdir}/source"
    mkdir -p "${bdir}/source/libressl-${libresslver}/build" && cd "${bdir}/source/libressl-${libresslver}/build"
    ../configure && make
    mkdir -p "${bdir}/source/libressl-${libresslver}/.openssl/lib"
    cd "${bdir}/source/libressl-${libresslver}/.openssl" && ln -s ../include
    cd "${bdir}/source/libressl-${libresslver}" && cp "build/crypto/.libs/libcrypto.a" "build/ssl/.libs/libssl.a" ".openssl/lib"   

    SSLPACK="libressl-${libresslver}"
fi


# Config nginx based on the flags passed to the script, if any
if [ $PASSENGER ]
then
    [ $(gem list rails | grep rails) ] && sudo gem install rails -v 4.2.7
    [ $(gem list passenger | grep passenger) ] && sudo gem install passenger
fi


# Setup DEB Rules
patch "${bdir}/source/debian/rules" "${rpath}/patches/${rules}"
[ $PASSENGER ] && EXTRACONFIG="$EXTRACONFIG --add-module=$(passenger-config --root)/src/nginx_module"
[ $HARDENING ] && EXTRACONFIG="$EXTRACONFIG --with-ld-opt='-Wl,-z,now'"
[ "$EXTRACONFIG" ] && sed -i "4 i\EXTRACONFIG = ${EXTRACONFIG}" "${bdir}/source/debian/rules"
sed -i "4 i\SSLPACK = ${SSLPACK}" "${bdir}/source/debian/rules"


# Build Nginx DEB
cd "${bdir}/source"
if [ $PASSENGER ]
then
    cd /usr/bin
    [ ! -e rake ] && sudo ln -s rake2.1 rake
    sudo -i -u root bash -c "cd ${bdir}/source; PATH=/usr/local/bin:$PATH dpkg-buildpackage -b"
else
    dpkg-buildpackage -b
fi
sudo chown -R $USER "$bdir"


# Install
sudo dpkg -i ${bdir}/*.deb
sudo systemctl daemon-reload
echo ""
sudo nginx -V
echo ""
sudo ldd /usr/sbin/nginx
echo ""
echo "Install complete!"
echo "You can start/enable nginx with systemctl command:"
echo ""
echo "    sudo systemctl start nginx"
echo "    sudo systemctl enable nginx"
echo ""
