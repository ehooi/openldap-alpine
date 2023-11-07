FROM alpine:3.18

RUN apk add --no-cache openldap openldap-clients openldap-back-mdb openldap-passwd-pbkdf2 openldap-overlay-memberof openldap-overlay-ppolicy openldap-overlay-refint

COPY bootstrap/schema/* /etc/openldap/schema/
COPY bootstrap/ldif /etc/openldap/ldif

COPY docker-entrypoint.sh /
RUN chmod +xr /docker-entrypoint.sh

RUN mkdir -p /run/slapd/ && chmod 700 /run/slapd/ && chown ldap:ldap /run/slapd/

ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 389 636
