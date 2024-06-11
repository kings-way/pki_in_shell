#!/bin/bash
# Date:   		2019-01-08
# Author: 		King's Way <io@stdio.io>
# Description:  Simple shell script to create certs (RSA or ECC, including SM2)

filepath=`readlink -f $0`
basedir=`dirname $filepath`
RSA_OR_CURVE="rsa"

OPENSSL_BIN="$(which openssl)"	 # Although openssl 1.1.1 supports SMx, but does not support cipher suites based on SMx
GMSSL_BIN="$basedir/bin/gmssl_git_203f9f"
COMMON_ARGS="-batch"


init_dir(){
	if [ -f "$basedir/root-ca" ]; then
		return
	fi

	## create dirs
	mkdir -p $basedir/{root-ca,sub-ca}/{db,certs,private}

	## prepare files
	touch $basedir/{root-ca,sub-ca}/db/index
	touch $basedir/{root-ca,sub-ca}/db/index.attr
	chmod 700 $basedir/{root-ca,sub-ca}/private
	#$OPENSSL_BIN rand -hex 16 > $basedir/root-ca/db/serial
	#$OPENSSL_BIN rand -hex 16 > $basedir/sub-ca/db/serial
	echo 1001 > $basedir/root-ca/db/crlnumber
	echo 1001 > $basedir/sub-ca/db/crlnumber

	cp $basedir/conf/root-ca.conf $basedir/root-ca/root-ca.conf
	cp $basedir/conf/sub-ca.conf $basedir/sub-ca/sub-ca.conf
}


gen_ca()
{
	if [ -f "$basedir/root-ca/root-ca.crt" ];then
		echo "Root CA is present, please delete it or run build.sh clean before generate a new root CA"
		return
	fi

	init_dir

	cd $basedir/root-ca

	## create private key and csr, private key will be stored in 'root-ca/private'
	if [ "$RSA_OR_CURVE" = "rsa" ];then
		## option1: 'req -new' to create priv-key and CSR in one line, openssl default to 3DES encryption (no AES)
		# $OPENSSL_BIN req -new -config root-ca.conf -out root-ca.csr -keyout private/root-ca.key -passout pass:zhimakaimen

		## option2: 'req -new' to create priv-key (unencrypted) and CSR, encrypt priv-key afterwards.
		$OPENSSL_BIN req -new -config root-ca.conf -out root-ca.csr -keyout private/root-ca.key -nodes
		$OPENSSL_BIN rsa -in private/root-ca.key -out private/root-ca.key -aes256 -passout pass:zhimakaimen 

		## option3: 'genrsa' to create priv-key(encrypted with aes), then 'req' to make CSR.
		# $OPENSSL_BIN genrsa -out private/root-ca.key -aes256 -passout pass:zhimakaimen 4096
		# $OPENSSL_BIN req -config root-ca.conf -new -key private/root-ca.key -out root-ca.csr -passin pass:zhimakaimen

	else
		## '-req new' will create RSA keys, not EC Curves, so we use 'ecparams' to create keys
		## 'ecparam' does not support '-aes' to encrypt priv-key, so we encrypt it afterwards
		if [ "$RSA_OR_CURVE" = "sm2" ];then REQ_PARAMS="-sm3"; else REQ_PARAMS=""; fi  # SM3 works with SM2
		$OPENSSL_BIN ecparam -genkey -name "$RSA_OR_CURVE" -out private/root-ca.key
		$OPENSSL_BIN req $REQ_PARAMS -new -config root-ca.conf -key private/root-ca.key -out root-ca.csr

		## 'openssl ec' can not encrypt SM2 priv-key
		if [ "$RSA_OR_CURVE" != "sm2" ];then
			$OPENSSL_BIN ec -in private/root-ca.key -aes256 -out private/root-ca.key -passout pass:zhimakaimen
		fi
	fi

	## self-signed, expiration: 30 years
	if [ "$RSA_OR_CURVE" = "sm2" ];then CA_PARAMS="-md sm3"; else CA_PARAMS=""; fi
	$OPENSSL_BIN ca $CA_PARAMS $COMMON_ARGS -selfsign -config root-ca.conf -rand_serial\
		-in root-ca.csr -out root-ca.crt\
		-extensions ca_ext -days 10950\
		-passin pass:zhimakaimen

}

gen_subca()
{
	if [ -f "$basedir/sub-ca/sub-ca.crt" ];then
		echo "Sub CA is present, please delete it or run build.sh clean before generate a new sub CA"
		return
	fi

	if [ ! -f "$basedir/root-ca/root-ca.crt" ];then
		echo "Root CA not present...  Building CA now..."
		gen_ca
	fi

	cd $basedir/sub-ca
	# 新建二级CA的私钥及签名请求，私钥保存在 sub-ca/private 目录下，
	# 生成过程中会提示输入密码对私钥进行加密（使用 -nodes 参数表示不对私钥加密）
	if [ "$RSA_OR_CURVE" = "rsa" ]; then
		# 使用 RSA，一次性生成私钥及签名请求，密钥位数由 sub-ca.conf 指定
		$OPENSSL_BIN req -new -config sub-ca.conf -nodes\
			-out sub-ca.csr -keyout private/sub-ca.key
	else
		if [ "$RSA_OR_CURVE" = "sm2" ];then REQ_PARAMS="-sm3"; else REQ_PARAMS=""; fi  # SM3 works with SM2
		$OPENSSL_BIN ecparam -genkey -name "$RSA_OR_CURVE" -out private/sub-ca.key
		$OPENSSL_BIN req $REQ_PARAMS -new -config sub-ca.conf -key private/sub-ca.key -out sub-ca.csr
	fi

	cd $basedir/root-ca
	if [ "$RSA_OR_CURVE" = "sm2" ];then CA_PARAMS="-md sm3"; else CA_PARAMS=""; fi
	$OPENSSL_BIN ca $CA_PARAMS $COMMON_ARGS -config root-ca.conf -rand_serial\
		-in $basedir/sub-ca/sub-ca.csr -out $basedir/sub-ca/sub-ca.crt\
		-extensions sub_ca_ext -passin pass:zhimakaimen

	# merge rootCA and subCA certs
	# (如果只需要维护一个二级CA的话，这样较为方便；
	# (但是如果需要多个二级CA，合适的途径应该是将不同的二级CA证书和其签发出来的证书合并
#	cat $basedir/root-ca/root-ca.crt $basedir/sub-ca/sub-ca.crt > $basedir/ca.crt

}

server()
{
	if [ ! -f "$basedir/root-ca/root-ca.crt" ];then
		echo "Root CA not present...  Building CA now..."
		gen_ca
	fi
	#if [ ! -f "$basedir/sub-ca/sub-ca.crt" ];then
	#	echo "Sub CA not present...  Building Sub CA now..."
	#	gen_subca
	#fi

	# create dirs
	mkdir $basedir/server
	cp $basedir/conf/openssl.cnf $basedir/server/
	cd $basedir/server

	CN=$1

	# create private key and cert request
	if [ "$RSA_OR_CURVE" = "rsa" ]; then
		$OPENSSL_BIN req -config openssl.cnf -new -nodes\
			-out "$CN.csr" -keyout "$CN.key"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"\
			-addext "subjectAltName=DNS:$CN,DNS:*.$CN"
	else
		if [ "$RSA_OR_CURVE" = "sm2" ];then REQ_PARAMS="-sm3"; else REQ_PARAMS=""; fi  # SM3 works with SM2
		$OPENSSL_BIN ecparam -genkey -name "$RSA_OR_CURVE" -out "$CN.key"
		$OPENSSL_BIN req $REQ_PARAMS -config openssl.cnf -new\
			-key "$CN.key" -out "$CN.csr"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"\
			-addext "subjectAltName=DNS:$CN,DNS:*.$CN"
	fi


	# sign the cert, (use subCA if exists), set cert usage by 'extensions' in config file.
	# 'server_ext' shall be pre-set in root-ca.conf or sub-ca.conf
	if [ -f "$basedir/sub-ca/sub-ca.crt" ];then
		cd $basedir/sub-ca
		CONF="sub-ca.conf"
	else
		cd $basedir/root-ca
		CONF="root-ca.conf"
	fi

	if [ "$RSA_OR_CURVE" = "sm2" ];then CA_PARAMS="-md sm3"; else CA_PARAMS=""; fi
	$OPENSSL_BIN ca $CA_PARAMS $COMMON_ARGS -config "$CONF" -rand_serial\
		-in $basedir/server/$CN.csr -out $basedir/server/$CN.crt\
		-extensions server_ext -passin pass:zhimakaimen
	
	# append subCA cert (if exists)
	if [ -f "$basedir/sub-ca/sub-ca.crt" ];then
		cat sub-ca.crt >> $basedir/server/$CN.crt
	fi

}


client()
{
	if [ ! -f "$basedir/root-ca/root-ca.crt" ];then
		echo "Root CA not present...  Building CA now..."
		gen_ca
	fi
	#if [ ! -f "$basedir/sub-ca/sub-ca.crt" ];then
	#	echo "Sub CA not present...  Building Sub CA now..."
	#	gen_subca
	#fi

	# create dirs
	mkdir $basedir/client
	cp $basedir/conf/openssl.cnf $basedir/client/
	cd $basedir/client

	CN=$1

	# create private key and cert request
	if [ "$RSA_OR_CURVE" = "rsa" ]; then
		$OPENSSL_BIN req -config openssl.cnf -new -nodes\
			-out "$CN.csr" -keyout "$CN.key"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"
	else
		if [ "$RSA_OR_CURVE" = "sm2" ];then REQ_PARAMS="-sm3"; else REQ_PARAMS=""; fi  # SM3 works with SM2
		$OPENSSL_BIN ecparam -genkey -name "$RSA_OR_CURVE" -out "$CN.key"
		$OPENSSL_BIN req $REQ_PARAMS -config openssl.cnf -new\
			-out "$CN.csr" -key "$CN.key"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"
	fi


	# sign the cert, (use subCA if exists), set cert usage by 'extensions' in config file.
	# 'client_ext' shall be pre-set in root-ca.conf or sub-ca.conf
	if [ -f "$basedir/sub-ca/sub-ca.crt" ];then
		cd $basedir/sub-ca
		CONF="sub-ca.conf"
	else
		cd $basedir/root-ca
		CONF="root-ca.conf"
	fi
	if [ "$RSA_OR_CURVE" = "sm2" ];then CA_PARAMS="-md sm3"; else CA_PARAMS=""; fi
	$OPENSSL_BIN ca $CA_PARAMS $COMMON_ARGS -config "$CONF" -rand_serial\
		-in $basedir/client/$CN.csr -out $basedir/client/$CN.crt\
		-extensions client_ext -passin pass:zhimakaimen

	# append subCA cert (if exists)
	if [ -f "$basedir/sub-ca/sub-ca.crt" ];then
		cat sub-ca.crt >> $basedir/client/$CN.crt
	fi

}

test_server()
{
	server test.com
	cd $basedir
	# Both the s_server and s_client won't send the full chain, 
	# which differs from what the Web Server and Browser do.
	# So we have to concatenate the CA and SubCA as a whole
	cat sub-ca/sub-ca.crt root-ca/root-ca.crt > /tmp/ca-bundle.crt

	if [ "$RSA_OR_CURVE" = "rsa" ]; then
		$OPENSSL_BIN s_server -accept 8443 -verify 2 -state\
			-CAfile /tmp/ca-bundle.crt\
			-cert server/test.com.crt\
			-key server/test.com.key
	else
		$GMSSL_BIN s_server -accept 8443 -verify 2 -state\
			-CAfile /tmp/ca-bundle.crt\
			-cert server/test.com.crt\
			-key server/test.com.key
	fi

}

test_client()
{
	client UserTest
	cd $basedir

	if [ "$RSA_OR_CURVE" = "rsa" ]; then
		$OPENSSL_BIN s_client -connect 127.0.0.1:8443\
			-verify 2 -state\
			-CAfile root-ca/root-ca.crt\
			-cert client/UserTest.crt\
			-key client/UserTest.key
				else
		$GMSSL_BIN s_client -connect 127.0.0.1:8443\
			-config $basedir/client/openssl.cnf\
			-verify 2 -state\
			-CAfile root-ca/root-ca.crt\
			-cert client/UserTest.crt\
			-key client/UserTest.key
	fi

}

verify()
{
	cd $basedir
	if [ -f "$basedir/sub-ca/sub-ca.crt" ];then
		SUB_CA_PARAMS="-untrusted sub-ca/sub-ca.crt"
	else
		SUB_CA_PARAMS=""
	fi

	for i in `ls server/*.crt client/*.crt`;
	do
		echo 
		$OPENSSL_BIN verify -show_chain\
			-CAfile root-ca/root-ca.crt $SUB_CA_PARAMS $i
	done

}

clean()
{
#	echo -n "Press [y] to delete all certs, including CA certs: "
#	read KEY
#	if [ "$KEY" = "y" ];then
		rm -rfv $basedir/root-ca
		rm -rfv $basedir/sub-ca
		rm -rfv $basedir/server
		rm -rfv $basedir/client
		rm -rfv $basedir/ca.crt
#		echo "Done!"
#	else
#		echo "Canceled!"
#	fi
}

usage()
{
	echo "================================"
	echo "Usage:"
	echo " ./build.sh rsa/ecc  gen_ca                # generate CA keys and certs"
	echo " ./build.sh rsa/ecc  gen_subca             # generate Sub CA keys and certs (implying: gen_ca)"
	echo " ./build.sh rsa/ecc  server wwww.test.com  # generate Server certs with CommonName: www.test.com (signed with CA if no subCA)"
	echo " ./build.sh rsa/ecc  client Client1        # generate client certs with CommonName: Client1 (signed with CA if no subCA)"
	echo ""
	echo " ./build.sh rsa/ecc  test_server           # generate a test server cert and run openssl s_server on 127.0.0.1:8443"
	echo " ./build.sh rsa/ecc  test_client           # generate a test client cert and run openssl s_client connecting 127.0.0.1:8443"
	echo " ./build.sh verify   	                     # verify every cert in ./server/*.crt and ./client/*.crt"
	echo " ./build.sh clean                          # delete everything, including root-ca and sub-ca dirs"
	echo " ./build.sh help                           # show this help"
}

help()
{
	usage
}

if [ $# -eq 0 ]; then 		# show help
	help
elif [ $# -eq 1 ]; then
	echo "Calling:$1"
	eval $1
else
	RSA_OR_CURVE="$1"		# specify RSA or ECC curve name
	if [ "$RSA_OR_CURVE" = "ecc" ];then
		RSA_OR_CURVE="prime256v1"
	fi
	echo "Calling:$2"
	eval $2 $3
fi
