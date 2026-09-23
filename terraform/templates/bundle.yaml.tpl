series: noble

machines:
  '0': {}
  '1': {}
  '2': {}
  '3': {}
  '4': {}
  '5': {}
  '6': {}
  '7': {}
  '8': {}
  '9': {}
  '10': {}
  '11': {}

applications:
  mysql-innodb-cluster:
    charm: ch:mysql-innodb-cluster
    channel: latest/edge
    series: noble
    num_units: 3
    constraints: mem=3072M
    to:
      - '0'
      - '1'
      - '2'

  rabbitmq-server:
    charm: ch:rabbitmq-server
    channel: latest/edge
    series: noble
    num_units: 1
    to:
      - '3'

  keystone:
    charm: ch:keystone
    channel: latest/edge
    series: noble
    num_units: 1
    options:
      openstack-origin: distro
    to:
      - '4'

  glance:
    charm: ch:glance
    channel: latest/edge
    series: noble
    num_units: 1
    options:
      openstack-origin: distro
    to:
      - '5'

  nova-cloud-controller:
    charm: ch:nova-cloud-controller
    channel: latest/edge
    series: noble
    num_units: 1
    options:
      network-manager: Neutron
      openstack-origin: distro
    to:
      - '6'

  placement:
    charm: ch:placement
    channel: latest/edge
    series: noble
    num_units: 1
    options:
      openstack-origin: distro
    to:
      - '7'

  neutron-api:
    charm: ch:neutron-api
    channel: latest/edge
    series: noble
    num_units: 1
    options:
      manage-neutron-plugin-legacy-mode: false
      flat-network-providers: physnet1
      neutron-security-groups: true
      openstack-origin: distro
    to:
      - '8'

  ovn-central:
    charm: ch:ovn-central
    channel: latest/edge
    series: noble
    num_units: 1
    options:
      source: distro
    to:
      - '9'

  vault:
    charm: ch:vault
    channel: latest/edge
    series: noble
    num_units: 1
    to:
      - '10'

  nova-compute:
    charm: ch:nova-compute
    channel: latest/edge
    series: noble
    num_units: 1
    options:
      openstack-origin: distro
      enable-live-migration: false
      config-flags: default_ephemeral_format=ext4
    to:
      - '11'

  nova-compute-nvidia-vgpu:
    charm: ch:nova-compute-nvidia-vgpu
    channel: latest/edge
    series: noble
    options:
      vgpu-mode: auto

  ovn-chassis:
    charm: ch:ovn-chassis
    channel: latest/edge
    series: noble
    options:
      ovn-bridge-mappings: "${ovn_bridge_mappings}"
      bridge-interface-mappings: "${ovn_bridge_interface_mappings}"

  neutron-api-plugin-ovn:
    charm: ch:neutron-api-plugin-ovn
    channel: latest/edge
    series: noble

  keystone-mysql-router:
    charm: ch:mysql-router
    channel: latest/edge
    series: noble

  nova-cloud-controller-mysql-router:
    charm: ch:mysql-router
    channel: latest/edge
    series: noble

  glance-mysql-router:
    charm: ch:mysql-router
    channel: latest/edge
    series: noble

  neutron-api-mysql-router:
    charm: ch:mysql-router
    channel: latest/edge
    series: noble

  placement-mysql-router:
    charm: ch:mysql-router
    channel: latest/edge
    series: noble

  vault-mysql-router:
    charm: ch:mysql-router
    channel: latest/edge
    series: noble

relations:
  - - neutron-api:amqp
    - rabbitmq-server:amqp
  - - neutron-api:neutron-api
    - nova-cloud-controller:neutron-api
  - - neutron-api:identity-service
    - keystone:identity-service
  - - neutron-api:neutron-plugin-api-subordinate
    - neutron-api-plugin-ovn:neutron-plugin
  - - neutron-api:certificates
    - vault:certificates
  - - nova-cloud-controller:amqp
    - rabbitmq-server:amqp
  - - nova-cloud-controller:identity-service
    - keystone:identity-service
  - - nova-cloud-controller:cloud-compute
    - nova-compute:cloud-compute
  - - nova-cloud-controller:image-service
    - glance:image-service
  - - nova-cloud-controller:certificates
    - vault:certificates
  - - nova-compute:amqp
    - rabbitmq-server:amqp
  - - nova-compute:image-service
    - glance:image-service
  - - nova-compute:neutron-plugin
    - ovn-chassis:nova-compute
  - - nova-compute:nova-vgpu
    - nova-compute-nvidia-vgpu:nova-vgpu
  - - glance:identity-service
    - keystone:identity-service
  - - glance:amqp
    - rabbitmq-server:amqp
  - - glance:certificates
    - vault:certificates
  - - placement:identity-service
    - keystone:identity-service
  - - placement:placement
    - nova-cloud-controller:placement
  - - placement:certificates
    - vault:certificates
  - - keystone:certificates
    - vault:certificates
  - - ovn-central:certificates
    - vault:certificates
  - - ovn-central:ovsdb-cms
    - neutron-api-plugin-ovn:ovsdb-cms
  - - ovn-chassis:certificates
    - vault:certificates
  - - ovn-chassis:ovsdb
    - ovn-central:ovsdb
  - - neutron-api-plugin-ovn:certificates
    - vault:certificates
  - - keystone:shared-db
    - keystone-mysql-router:shared-db
  - - keystone-mysql-router:db-router
    - mysql-innodb-cluster:db-router
  - - nova-cloud-controller:shared-db
    - nova-cloud-controller-mysql-router:shared-db
  - - nova-cloud-controller-mysql-router:db-router
    - mysql-innodb-cluster:db-router
  - - glance:shared-db
    - glance-mysql-router:shared-db
  - - glance-mysql-router:db-router
    - mysql-innodb-cluster:db-router
  - - neutron-api:shared-db
    - neutron-api-mysql-router:shared-db
  - - neutron-api-mysql-router:db-router
    - mysql-innodb-cluster:db-router
  - - placement:shared-db
    - placement-mysql-router:shared-db
  - - placement-mysql-router:db-router
    - mysql-innodb-cluster:db-router
  - - vault:shared-db
    - vault-mysql-router:shared-db
  - - vault-mysql-router:db-router
    - mysql-innodb-cluster:db-router
