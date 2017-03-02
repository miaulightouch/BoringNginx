#!/bin/bash
set -e
shopt -s extglob
if [ "$(id -u)" -eq 0 ]; then echo -e "This script is not intended to be run as root.\nExiting." && exit 1; fi


# Default settings
rpath="$(cd $(dirname $0) && pwd)" # Run path
bdir="/tmp/patchednginx-$RANDOM" # Set build directory

ngxver=1.10.3                                                    # Nginx stable version
spdy=nginx-spdy.patch
dtls=nginx__dynamic_tls_records.patch

boring=boring.patch                                              # boringssl patch
opensslver=1.0.2k                                                # OpenSSL version
libresslver=2.4.5                                                # LibreSSL version
chacha20=openssl__chacha20_poly1305_draft_and_rfc_ossl102j.patch # CF ChaCha20_Poly1305 patch

spec=spec.patch                                                  # RPM spec patch



mainlinever=1.11.10                                              # Nginx Mainline version
mainline_spdy=nginx-spdy-1.11.10.patch
mainline_dtls=nginx__1.11.5_dynamic_tls_records.patch
mainline_boring=boring.patch

# Handle arguments passed to the script. Currently only accepts the flag to
# include passenger at compile time,but I might add a help section or more options soon.
while [ "$#" -gt 0 ]
do
    case $1 in
        --passenger|-passenger|passenger) PASSENGER="1"; echo ""; echo "Phusion Passenger module enabled."; shift;;
        --boringssl|-boringssl|boringssl) BORINGSSL="1"; shift;;
        --openssl|-openssl|openssl) OPENSSL="1"; shift;;
        --libressl|-libressl|libressl) LIBRESSL="1"; shift;;
        --mainline|-mainline|mainline)
            Mainline=mainline/;
            ngxver=$mainlinever;
            spdy=$mainline_spdy;
            dtls=$mainline_dtls;
            boring=$mainline_boring;
            shift;;
        *)
            echo "Invalid argument: $1"
            echo ""
            echo "Usage: $0 [Option]..."
            echo ""
            echo "--mainline     Build Nginx Mainline"
            echo ""
            echo "--boringssl    Use BoringSSL source"
            echo "--libressl     Use LibreSSL source"
            echo "--openssl      Use OpenSSL source with ChaCha20_Poly1305 patch"
            echo ""
            echo "--passenger    Build with passenger module"
            exit 10
        ;;
    esac
done
[ ! "$BORINGSSL" -o "$LIBRESSL" ] && OPENSSL="1" # Use OpenSSL if not set

# Prompt our user before we start removing stuff
CONFIRMED=0
echo ""
echo -e "This script will remove any versions of Nginx you installed using yum, and\nreplace any version of Nginx built with a previous version of this script."
echo -e "\nNginx Version: $ngxver"
while true
do
    echo ""
    read -p "Do you wish to continue? (Y/N) " answer
    case $answer in
        [yY]* ) CONFIRMED=1; break;;
        [nN]* ) exit 10; break;;
        * ) echo "Please enter 'Y' to continue or ^C to exit.";;
    esac
done
if [ "$CONFIRMED" -eq 0 ]; then echo -e "Something went wrong.\nExiting." && exit 1; fi


# Install deps
sudo systemctl stop nginx || true
sudo systemctl disable nginx || true
sudo yum -y install patch gcc gcc-c++ rpm-build perl-devel perl-ExtUtils-Embed GeoIP-devel pcre-devel libxslt-devel gd-devel


# Prepare source
mkdir "$bdir" && mkdir -p "$rpath/source" && cd "$rpath/source"
curl -LO --retry 3 "http://nginx.org/packages/${Mainline}centos/7/SRPMS/nginx-${ngxver}-1.el7.ngx.src.rpm"
rpm -ih --define "_topdir $bdir" "nginx-$ngxver-1.el7.ngx.src.rpm"

cp "${rpath}/patches/${spdy}" "${bdir}/SOURCES"
cat "${rpath}/patches/${dtls}" >> "${bdir}/SOURCES/${spdy}"

# Prepare SSL
if [ $OPENSSL ]
then
    mkdir -p "${rpath}/openssl" && cd "${rpath}/openssl"
    until [ "$VALID" == "1" ]; do
        [ $WRONG ] && curl -LO --retry 3 "https://www.openssl.org/source/openssl-${opensslver}.tar.gz"
        curl -LO --retry 3 "https://www.openssl.org/source/openssl-${opensslver}.tar.gz.sha256"
        sha256sum openssl-${opensslver}.tar.gz | grep $(cat openssl-${opensslver}.tar.gz.sha256) && VALID=1 || WRONG=1
    done

    tar xf "${rpath}/openssl/openssl-${opensslver}.tar.gz" -C "${bdir}/SOURCES"
    patch -d "${bdir}/SOURCES/openssl-${opensslver}" -p1 < "${rpath}/patches/$chacha20"
    touch "${bdir}/SOURCES/openssl-${opensslver}/Makefile"

    SSLPACK="openssl-${opensslver}"
fi

if [ $BORINGSSL ]
then
    sudo yum -y install cmake git golang

    if [ -e "${rpath}/boringssl" ]
    then
        cd "${rpath}/boringssl"
        git fetch && git pull
    else
        git clone "https://boringssl.googlesource.com/boringssl" "${rpath}/boringssl"
    fi

    cp -r "${rpath}/boringssl" "$bdir/SOURCES"
    mkdir -p "${bdir}/SOURCES/boringssl/build" && cd "${bdir}/SOURCES/boringssl/build"
    cmake -DCMAKE_C_FLAGS=-fPIC -DCMAKE_CXX_FLAGS=-fPIC ../ && make
    mkdir -p "${bdir}/SOURCES/boringssl/.openssl/lib"
    cd "${bdir}/SOURCES/boringssl/.openssl" && ln -s ../include
    cd "${bdir}/SOURCES/boringssl" && cp "build/crypto/libcrypto.a" "build/ssl/libssl.a" ".openssl/lib"
    cat "${rpath}/patches/${boring}" >> "${bdir}/SOURCES/$spdy"

    SSLPACK="boringssl"
fi

if [ $LIBRESSL ]
then
    mkdir -p "${rpath}/libressl" && cd "${rpath}/libressl"
    until [ "$VALID" == "1" ]; do
        [ $WRONG ] && curl -LO --retry 3 "http://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${libresslver}.tar.gz"
        curl -LO --retry 3 "http://ftp.openbsd.org/pub/OpenBSD/LibreSSL/SHA256"
        grep libressl-${libresslver}.tar.gz SHA256 | sha256sum -c && VALID=1 || WRONG=1
    done
    tar xf "${rpath}/libressl/libressl-${libresslver}.tar.gz" -C "${bdir}/SOURCES"
    sed -i 's/\.\/configure/CFLAGS=-fPIC \.\/configure/g' "${bdir}/SOURCES/libressl-${libresslver}/config"

    SSLPACK="libressl-${libresslver}"
fi


# Config nginx based on the flags passed to the script, if any
if [ $PASSENGER ]
then
    [ ! $(gem list rails | grep rails) ] && sudo gem install rails -v 4.2.7
    [ ! $(gem list passenger | grep passenger) ] && sudo gem install passenger
fi


# Setup RPM Spec
patch "${bdir}/SPECS/nginx.spec" "${rpath}/patches/$spec"
[ $PASSENGER ] && EXTRACONFIG="$EXTRACONFIG --add-module=$(passenger-config --root)/src/nginx_module"
sed -i "1 i\%define EXTRACONFIG ${EXTRACONFIG-;}" "${bdir}/SPECS/nginx.spec"
sed -i "1 i\%define SSLPACK ${SSLPACK}" "${bdir}/SPECS/nginx.spec"
sed -i "1 i\%define SPDY_PATCH $spdy" "${bdir}/SPECS/nginx.spec"
sed -i "1 i\%define dist .el%{rhel}" "${bdir}/SPECS/nginx.spec"

# Build Nginx RPM
if [ $PASSENGER ]
then
    sudo -i -u root bash -c "PATH=/usr/local/bin:$PATH rpmbuild -bb --define '_topdir $bdir' ${bdir}/SPECS/nginx.spec"
else
    rpmbuild -bb --define "_topdir $bdir" "${bdir}/SPECS/nginx.spec"
fi
sudo chown -R $USER "$bdir"


# Install
sudo rpm -Uvh --force "${bdir}/RPMS/${HOSTTYPE}/nginx-*.rpm"
sudo systemctl daemon-reload
echo ""
nginx -V
echo ""
ldd /usr/sbin/nginx
echo ""
echo "Install complete!"
echo "You can start/enable nginx with systemctl command:"
echo ""
echo "    sudo systemctl start nginx"
echo "    sudo systemctl enable nginx"
echo ""
