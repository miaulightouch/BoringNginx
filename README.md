PatchedNginx
=========
* forked from [BoringNginx](https://github.com/ajhaydock/BoringNginx)

<img align="right" src="https://raw.githubusercontent.com/miaulightouch/PatchedNginx/master/nginx.png" alt="Nginx Logo" title="Nginx">

Build script to build current stable Nginx with SSL source list below:
* [cloudflare patched](https://github.com/cloudflare/sslconfig) OpenSSL
* Google's BoringSSL
* OpenBSD's LibreSSL

And provide addition feature:
* add spdy support (from [@felixbuenemann](https://github.com/felixbuenemann/sslconfig/blob/7c23d2791857f0b07e3008ba745bcf48d8d6b170/patches/nginx_1_9_15_http2_spdy.patch))
* build with passenger module [**PLEASE READ BELOW**](#enabling-passenger-for-ruby-on-rails)
* build with full relro

This allows you to use some state-of-the-art crypto features not yet available in the stable branch of OpenSSL, like [ChaCha20-Poly1305](https://boringssl.googlesource.com/boringssl/+/de0b2026841c34193cacf5c97646b38439e13200) as a cipher/MAC combo, and [X25519](https://boringssl.googlesource.com/boringssl/+/4fb0dc4b031df7c9ac9d91fc34536e4e08b35d6a) (aka Curve25519) as the ECDHE curve provider if you want to get away from using [unsafe NIST curves](https://safecurves.cr.yp.to/) (though you probably want to check the X25519 [browser support matrix](https://www.chromestatus.com/feature/5682529109540864) before trying that).

It would compat as DEB/RPM package, you can easily install/uninstall via package manager.

### Build specified version
```
Usage: build-*.sh [Option]...

--boringssl    Use BoringSSL source
--libressl     Use LibreSSL source
--openssl      Use OpenSSL source with ChaCha20_Poly1305 patch

--passenger    Build with passenger module

--hardening    Enable full relro
```

If you execute `./build-*.sh` without parameter, it would be `./build-*.sh 1.10.1 --openssl`

For example, if you want build 1.11.2 with LibreSSL, passenger module, enable full relro:
`./build-centos.sh 1.11.2 libressl passenger hardening`

You can specify newer nginx version, but it may not work.

| Version      | Tested On     |          |
|--------------|---------------|----------|
| Nginx 1.10.0 | Debian Jessie | CentOS 7 |
| Nginx 1.10.1 | Debian Jessie | CentOS 7 |
| Nginx 1.11.0 | Debian Jessie | CentOS 7 |
| Nginx 1.11.1 | Debian Jessie | CentOS 7 |
| Nginx 1.11.2 | Debian Jessie | CentOS 7 |

### Enabling PHP
To enable PHP on this installation of nginx, it is as simple as installing the `php-fpm` package and adding the regular PHP directives to your `/etc/nginx/nginx.conf` file. On Grsec/PaX kernels you do not need to set any MPROTECT exceptions on any binaries to get a fully working server with PHP support (I have now tested this).

To enable PHP, I add the following to my `nginx.conf` server block. The `try_files` directive ensures that Nginx does not forward bad requests to the PHP processor, but you may need to tweak this for your specific web application:
```nginx
	location ~ \.php$ {
		try_files $uri =404;
		fastcgi_split_path_info ^(.+\.php)(/.+)$;
		fastcgi_pass unix:/var/run/php5-fpm.sock;
		fastcgi_index index.php;
		fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
		include fastcgi_params;
	}
```

You will also need to ensure that the `index` directive of your site is set up to serve `index.php` files.

### Enabling Passenger (for Ruby-on-Rails)
To enable [Phusion Passenger](https://www.phusionpassenger.com/) in Nginx, you need to compile the Passenger module into Nginx. Passenger has a helpful script to do this for you (`passenger-install-nginx-module`), but that makes it difficult to . Instead, I have developed a version of this script tweaked for Passenger that you can run after installing the Passenger gem and hopefully enable full Passenger support in Nginx.

Install Ruby:
```bash
CentOS7: sudo yum install rubygems ruby-devel libcurl-devel
Debian:  sudo apt install ruby ruby-dev
```

Install Rails:
```bash
sudo gem install rails -v 4.2.7
```

Install Passenger (tool for deploying Rails apps):
```bash
sudo gem install passenger
```

To run the Passenger version of the BoringNginx build script:
```bash
./build-*.sh --passenger
```

Since building in this fashion bypasses Passenger's auto-compile script that automatically builds its module into Nginx for you, you will also miss out on some of the other things the script does.

If you attempt to run a Rails app and end up with the following in your Nginx `error.log`:
```
The PassengerAgent binary is not compiled. Please run this command to compile it: /var/lib/gems/2.1.0/gems/passenger-5.0.29/bin/passenger-config compile-agent
```

You should be able to fix this by running the following command:
```bash
sudo $(passenger-config --root)/bin/passenger-config compile-agent
```

To find out what configuration directives you need to set inside your `nginx.conf` file before Passenger will function, please see the [Nginx Config Reference](https://www.phusionpassenger.com/library/config/nginx/reference/) page on the Passenger site.

For reference, I added the following lines to the `http {}` block of my Nginx config:
```nginx
	passenger_root			/var/lib/gems/2.1.0/gems/passenger-5.0.29; # This is the result of "passenger-config --root"
	passenger_ruby			/usr/bin/ruby;
```

And the following line to my `server {}` block:
```nginx
	passenger_enabled		on;
```

If you have `location {}` blocks nested within your `server {}` block, you need to make sure that the `passenger_enabled on;` directive seen above is included in every location block that should be serving a Rails app.
