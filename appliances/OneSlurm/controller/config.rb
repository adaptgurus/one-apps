# frozen_string_literal: true

ONEAPP_LDAP_ENABLE        = env :ONEAPP_LDAP_ENABLE, 'NO'
ONEAPP_LDAP_DOMAIN        = env :ONEAPP_LDAP_DOMAIN, 'slurm.local'
ONEAPP_LDAP_ADMIN_USER    = env :ONEAPP_LDAP_ADMIN_USER, 'admin'
ONEAPP_LDAP_ADMIN_PASSWORD = env :ONEAPP_LDAP_ADMIN_PASSWORD, ''
ONEAPP_LDAP_URL           = env :ONEAPP_LDAP_URL, ''
ONEAPP_LDAP_BIND_USER     = env :ONEAPP_LDAP_BIND_USER, ''
ONEAPP_LDAP_BIND_PASSWORD = env :ONEAPP_LDAP_BIND_PASSWORD, ''

LDAP_CONFIGURED_MARKER = '/etc/ldap/one_slurm_ldap_configured'
LDAP_EXTERNAL_ADMIN_DN = 'gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth'
