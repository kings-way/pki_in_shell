#!/bin/bash
# Date:   		2019-01-08
# Author: 		King's Way <io@stdio.io>
# Description:  Simple shell script to create certs (RSA or SM2)

filepath=`readlink -f $0`
basedir=`dirname $filepath`
FLAG_SM2=0

OPENSSL_BIN="$basedir/bin/openssl_1.1.1a_static"	 # openssl 1.1.1 虽然支持了SM2\SM3\SM4算法，但是还是缺少相关 cipher suite 的支持
TEST_OPENSSL_BIN="$basedir/bin/gmssl_git_203f9f"
COMMON_ARGS="-batch"


init_dir(){
	if [ -f "$basedir/root-ca" ]; then
		return
	fi

	# 分别建立root-ca和sub-ca目录
	mkdir -p $basedir/{root-ca,sub-ca}/{db,certs,private}

	# 准备一些文件
	touch $basedir/{root-ca,sub-ca}/db/index
	touch $basedir/{root-ca,sub-ca}/db/index.attr
	chmod 700 $basedir/{root-ca,sub-ca}/private
#	$OPENSSL_BIN rand -hex 16 > $basedir/root-ca/db/serial	# 下面的openssl已经加了 -rand_serial 参数，自动生成20字节长的随机数
#	$OPENSSL_BIN rand -hex 16 > $basedir/sub-ca/db/serial
	echo 1001 > $basedir/root-ca/db/crlnumber
	echo 1001 > $basedir/sub-ca/db/crlnumber

	# 准备配置文件
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

	# 新建私钥及签名请求，私钥保存在 root-ca/private 目录下
	if [ $FLAG_SM2 -eq 0 ];then
		# 方式1. 使用 req -new 一次性生成 RSA 私钥及签名请求，默认3des加密(无法指定AES)
		# $OPENSSL_BIN req -new -config root-ca.conf -out root-ca.csr -keyout private/root-ca.key -passout pass:zhimakaimen

		# 方式2. 使用 req -new 一次性生成 RSA 私钥(不加密)及签名请求，然后再另外对私钥进行加密
		$OPENSSL_BIN req -new -config root-ca.conf -out root-ca.csr -keyout private/root-ca.key -nodes
		$OPENSSL_BIN rsa -in private/root-ca.key -out private/root-ca.key -aes256 -passout pass:zhimakaimen 

		# 方式3. 使用 RSA 先生成私钥，然后生成签名请求， 这样可以制定使用aes对私钥进行加密
		# $OPENSSL_BIN genrsa -out private/root-ca.key -aes256 -passout pass:zhimakaimen 4096
		# $OPENSSL_BIN req -config root-ca.conf -new -key private/root-ca.key -out root-ca.csr -passin pass:zhimakaimen

	else
		# 方式4. 使用静态编译的 openssl 1.1.1a 版本来生成国密 SM2 算法的私钥 
		#			( openssl 1.1.1之后的版本才添加SM2支持, 且 req -new 默认生成rsa密钥对，不支持制定 SM2 算法
		# 			( openssl ecparm 生成 SM2 私钥的时候不支持 -aes 加密参数, 因此最后进行加密
		$OPENSSL_BIN ecparam -genkey -name SM2 -out private/root-ca.key
		$OPENSSL_BIN req -new -config root-ca.conf -key private/root-ca.key -out root-ca.csr
		$OPENSSL_BIN ec -in private/root-ca.key -aes256 -out private/root-ca.key -passout pass:zhimakaimen
	fi


	# 进行自签名，生成证书默认保存在当前目录下(root-ca.crt)，同时root-ca/certs目录下存在一个以证书序列号为文件名保存的备份
	# 在这里指定根CA有效时间: 30年
	$OPENSSL_BIN ca $COMMON_ARGS -selfsign -config root-ca.conf -rand_serial\
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
	if [ $FLAG_SM2 -eq 0 ]; then
		# 使用 RSA，一次性生成私钥及签名请求，密钥位数由 sub-ca.conf 指定
		$OPENSSL_BIN req -new -config sub-ca.conf -nodes\
			-out sub-ca.csr -keyout private/sub-ca.key
	else
		# 使用静态编译的 $OPENSSL_BIN 1.1.1a 版本来生成国密 SM2 算法的私钥 
		# ($OPENSSL_BIN 1.1.1之后的版本才添加SM2支持
		$OPENSSL_BIN ecparam -genkey -name SM2 -out private/sub-ca.key
		$OPENSSL_BIN req -new -config sub-ca.conf -key private/sub-ca.key -out sub-ca.csr
	fi

	# 使用根证书的私钥签发二级CA，证书默认保存在当前目录下 (sub-ca.crt)，
	# 同时root-ca/certs目录下存在一个以证书序列号为文件名保存的备份
	cd $basedir/root-ca
	$OPENSSL_BIN ca $COMMON_ARGS -config root-ca.conf -rand_serial\
		-in $basedir/sub-ca/sub-ca.csr -out $basedir/sub-ca/sub-ca.crt\
		-extensions sub_ca_ext -passin pass:zhimakaimen

	# 合并根CA和二级CA的证书
	# (如果只需要维护一个二级CA的话，这样较为方便；
	# (但是如果需要多个二级CA，合适的途径应该是将不同的二级CA证书和其签发出来的证书合并
#	cat $basedir/root-ca/root-ca.crt $basedir/sub-ca/sub-ca.crt > $basedir/ca.crt

}

server()
{
	if [ ! -f "$basedir/sub-ca/sub-ca.crt" ];then
		echo "Sub CA not present...  Building Sub CA now..."
		gen_subca
		
	fi
	# 新建目录，保存相关文件
	mkdir $basedir/server
	cp $basedir/conf/openssl.cnf $basedir/server/
	cd $basedir/server

	CN=$1

	# 创建服务器证书私钥及签名请求
	if [ $FLAG_SM2 -eq 0 ]; then
		# RSA 的版本：
		$OPENSSL_BIN req -config openssl.cnf -new -nodes\
			-out "$CN.csr" -keyout "$CN.key"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"\
			-addext "subjectAltName=DNS:$CN,DNS:*.$CN"
	else
		# SM2 的版本：
		$OPENSSL_BIN ecparam -genkey -name SM2 -out "$CN.key"
		$OPENSSL_BIN req -config openssl.cnf -new\
			-key "$CN.key" -out "$CN.csr"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"\
			-addext "subjectAltName=DNS:$CN,DNS:*.$CN"
	fi


	# 使用二级 CA 对其签名，通过 “extensions” 参数限定证书用途
	# (server_ext在sub-ca.conf中已预先配置
	cd $basedir/sub-ca
	$OPENSSL_BIN ca $COMMON_ARGS -config sub-ca.conf -rand_serial\
		-in $basedir/server/$CN.csr -out $basedir/server/$CN.crt\
		-extensions server_ext
	
	# 合并二级CA证书
	cat sub-ca.crt >> $basedir/server/$CN.crt

}


client()
{
	if [ ! -f "$basedir/sub-ca/sub-ca.crt" ];then
		echo "Sub CA not present...  Building Sub CA now..."
		gen_subca
	fi

	# 新建目录，保存相关文件
	mkdir $basedir/client
	cp $basedir/conf/openssl.cnf $basedir/client/
	cd $basedir/client

	CN=$1

	# 创建客户端证书私钥及签名请求
	if [ $FLAG_SM2 -eq 0 ]; then
		# RSA 的版本：
		$OPENSSL_BIN req -config openssl.cnf -new -nodes\
			-out "$CN.csr" -keyout "$CN.key"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"
	else
		# SM2 的版本：
		$OPENSSL_BIN ecparam -genkey -name SM2 -out "$CN.key"
		$OPENSSL_BIN req -config openssl.cnf -new\
			-out "$CN.csr" -key "$CN.key"\
			-subj "/C=CN/ST=Beijing/L=Beijing/O=Test Corp/CN=$CN"
	fi


	# 使用二级 CA 对其签名，通过“extensions”参数限定证书用途
	# (server_ext在sub-ca.conf中已预先配置
	cd $basedir/sub-ca
	$OPENSSL_BIN ca $COMMON_ARGS -config sub-ca.conf -rand_serial\
		-in $basedir/client/$CN.csr -out $basedir/client/$CN.crt\
		-extensions client_ext

	# 合并二级CA证书
	cat sub-ca.crt >> $basedir/client/$CN.crt

}

test_server()
{
	server test.com
	cd $basedir
	# Both the s_server and s_client won't send the full chain, 
	# which differs from what the Web Server and Browser do.
	# So we have to concatenate the CA and SubCA as a whole
	cat sub-ca/sub-ca.crt root-ca/root-ca.crt > /tmp/ca-bundle.crt

	if [ $FLAG_SM2 -eq 0 ]; then
		$OPENSSL_BIN s_server -accept 8443 -verify 2 -state\
			-CAfile /tmp/ca-bundle.crt\
			-cert server/test.com.crt\
			-key server/test.com.key
	else
		$TEST_OPENSSL_BIN s_server -accept 8443 -verify 2 -state\
			-CAfile /tmp/ca-bundle.crt\
			-cert server/test.com.crt\
			-key server/test.com.key
	fi

}

test_client()
{
	client UserTest
	cd $basedir

	if [ $FLAG_SM2 -eq 0 ]; then
		$OPENSSL_BIN s_client -connect 127.0.0.1:8443\
			-verify 2 -state\
			-CAfile root-ca/root-ca.crt\
			-cert client/UserTest.crt\
			-key client/UserTest.key
	else
		$TEST_OPENSSL_BIN s_client -connect 127.0.0.1:8443\
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
	for i in `ls server/*.crt client/*.crt`;
	do
		echo 
		$OPENSSL_BIN verify -show_chain\
			-CAfile root-ca/root-ca.crt -untrusted sub-ca/sub-ca.crt $i
	done

}

clean()
{
	rm -rf $basedir/root-ca
	rm -rf $basedir/sub-ca
	rm -rf $basedir/server
	rm -rf $basedir/client
	rm -rf $basedir/ca.crt
}

usage()
{
	echo "================================"
	echo "Usage:"
	echo " ./build.sh rsa/sm2 gen_ca                # generate CA keys and certs"
	echo " ./build.sh rsa/sm2 gen_subca             # generate Sub CA keys and certs (implying: gen_ca)"
	echo " ./build.sh rsa/sm2 server wwww.test.com  # generate Server certs with CommonName: www.test.com (implying: gen_subca)"
	echo " ./build.sh rsa/sm2 client Client1        # generate client certs with CommonName: Client1 (implying: gen_subca)"
	echo ""
	echo " ./build.sh rsa/sm2 test_server           # generate a test server cert and run openssl s_server on 127.0.0.1:8443"
	echo " ./build.sh rsa/sm2 test_client           # generate a test client cert and run openssl s_client connecting 127.0.0.1:8443"
	echo " ./build.sh verify                        # verify every cert in ./server/*.crt and ./client/*.crt"
	echo " ./build.sh clean                         # delete everything, including root-ca and sub-ca dirs"
	echo " ./build.sh help                          # show this help"
}

help()
{
	usage
}

if [ $# -eq 0 ]; then
	help
elif [ $# -eq 1 ];then
	echo "Calling:$1"
	eval $1
else
	if [ "$1" = "sm2" ];then
		FLAG_SM2=1
	fi
	echo "Calling:$2"
	eval $2 $3
fi
