## Simple shell script to create certs (RSA or SM2)

----

	Usage:
	 ./build.sh rsa/ecc gen_ca              # generate CA keys and certs
	 ./build.sh rsa/ecc gen_subca           # generate Sub CA keys and certs (implying: gen_ca)
	 ./build.sh rsa/ecc server test.com     # generate Server certs with CommonName: test.com (signed with CA if no subCA)
	 ./build.sh rsa/ecc client Client1      # generate client certs with CommonName: Client1 (signed with CA if no subCA)

	 ./build.sh rsa/ecc test_server         # generate a test server cert and run openssl s_server on 127.0.0.1:8443
	 ./build.sh rsa/ecc test_client         # generate a test client cert and run openssl s_client connecting 127.0.0.1:8443
	 ./build.sh verify   	                # verify every cert in ./server/*.crt and ./client/*.crt
	 ./build.sh clean                       # delete everything, including root-ca and sub-ca dirs
	 ./build.sh help                        # show this help
