#!/bin/sh

# escape url
_escurl() { echo $1 | sed 's|/|%2F|g' ;}

SLAPD_CONF_DIR=/slapd/slapd.d
SLAPD_DATA_DIR=/slapd/mdb
# Socket name for IPC
SLAPD_IPC_SOCKET=/run/slapd/ldapi
SLAPD_CONF=/etc/openldap/slapd.conf
SLAPD_LOG_LEVEL=${SLAPD_LOG_LEVEL:-stats}

CA_CERT=/cert/ca.crt
TLS_KEY=/cert/tls.key
TLS_CERT=/cert/tls.crt

if [[ ! -d ${SLAPD_CONF_DIR} ]]; then
    if [[ -z "$SLAPD_ROOTDN" ]]; then
        echo -n >&2 "Error: SLAPD_ROOTDN not set. "
        echo >&2 "Did you forget to add -e SLAPD_ROOTDN=... ?"
        exit 1
    fi
    if [[ -z "$SLAPD_ROOTPW" ]]; then
        echo -n >&2 "Error: SLAPD_ROOTPW not set. "
        echo >&2 "Did you forget to add -e SLAPD_ROOTPW=... ?"
        exit 1
    fi

    mkdir -p ${SLAPD_CONF_DIR}
    chmod -R 700 ${SLAPD_CONF_DIR}
    chown -R ldap:ldap ${SLAPD_CONF_DIR}

    mkdir -p ${SLAPD_DATA_DIR}
    chmod -R 700 ${SLAPD_DATA_DIR}
    chown -R ldap:ldap ${SLAPD_DATA_DIR}

    # builtin schema
    cat <<EOF > "$SLAPD_CONF"
include /etc/openldap/schema/core.schema
include /etc/openldap/schema/cosine.schema
include /etc/openldap/schema/inetorgperson.schema
include /etc/openldap/schema/rfc2307bis.schema
include /etc/openldap/schema/openssh-lpk.schema
EOF

    # tls cert and key
    if [[ -f "${TLS_CERT}" ]] && [[ -f "${TLS_KEY}" ]]; then
        if [[ -f ${CA_CERT} ]]; then
            echo "TLSCACertificateFile ${CA_CERT}" >> "$SLAPD_CONF"
        fi
        echo "TLSCertificateFile ${TLS_CERT}" >> "$SLAPD_CONF"
        echo "TLSCertificateKeyFile ${TLS_KEY}" >> "$SLAPD_CONF"
        echo "TLSCipherSuite HIGH:-SSLv2:-SSLv3" >> "$SLAPD_CONF"
    fi

    cat <<EOF >> "$SLAPD_CONF"
pidfile     /run/slapd/slapd.pid
argsfile    /run/slapd/slapd.args
modulepath  /usr/lib/openldap
moduleload  back_mdb.so
moduleload  pw-pbkdf2.so
disallows   bind_anon

database config
rootdn "gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth"
access to *
    by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
    by * break

database mdb
suffix "${SLAPD_SUFFIX}"
rootdn "${SLAPD_ROOTDN}"
rootpw $(slappasswd -o module-load=pw-pbkdf2.so -h {PBKDF2-SHA512} -s "${SLAPD_ROOTPW}")
directory ${SLAPD_DATA_DIR}
maxsize 67108864
index objectClass eq
access to attrs=userPassword,shadowLastChange
    by self =xw
    by dn="${SLAPD_ROOTDN}" write
    by anonymous auth
    by * none
access to *
    by dn.base="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
    by dn="${SLAPD_ROOTDN}" write
    by dn.children=ou=clients,dc=epopsoft,dc=io read
    by * none
password-hash {PBKDF2-SHA512}
EOF

    echo "Starting slapd to convert config and creating mdb"
    slapd -h "ldapi://$(_escurl ${SLAPD_IPC_SOCKET})" -u ldap -g ldap -f ${SLAPD_CONF} -F ${SLAPD_CONF_DIR}

    echo "Waiting for slapd to be ready"
    until ldapsearch -Y EXTERNAL -Q -H ldapi://$(_escurl ${SLAPD_IPC_SOCKET}) -s base >/dev/null; do sleep 1; done

    # delete converted slapd.conf
    rm -f ${SLAPD_CONF} /etc/openldap/slapd.ldif

    echo "Create Directory..."

    ldapadd -Y EXTERNAL -H ldapi://$(_escurl ${SLAPD_IPC_SOCKET}) <<EOF
dn: ${SLAPD_SUFFIX}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${SLAPD_ORGANIZATION}
dc: ${SLAPD_DOMAIN}
EOF

    echo "Adding additional config from /etc/openldap/ldif/*.ldif"
    for f in /etc/openldap/ldif/*.ldif; do
        echo "> $f"
        ldapmodify -Y EXTERNAL -H ldapi://$(_escurl ${SLAPD_IPC_SOCKET}) -f ${f} -c -d "${LDAPADD_DEBUG_LEVEL}"
    done

    echo 'Stopping slapd'
    kill $(cat /run/slapd/slapd.pid)
    sleep 2
fi

if [[ -f "${TLS_CERT}" ]] && [[ -f "${TLS_KEY}" ]]; then
    echo "Starting LDAPS server..."
    exec slapd -h "ldaps:/// ldapi://$(_escurl ${SLAPD_IPC_SOCKET})" -F ${SLAPD_CONF_DIR} -u ldap -g ldap -d "${SLAPD_LOG_LEVEL}"
else
    echo "Starting LDAP server..."
    exec slapd -h "ldap:/// ldapi://$(_escurl ${SLAPD_IPC_SOCKET})" -F ${SLAPD_CONF_DIR} -u ldap -g ldap -d "${SLAPD_LOG_LEVEL}"
fi
