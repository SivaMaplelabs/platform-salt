{% set flavor_cfg = pillar['pnda_flavor']['states'][sls] %}

{% set packages_server = pillar['packages_server']['base_uri'] %}
{% set gobblin_version = pillar['gobblin']['release_version'] %}

{% if grains['hadoop.distro'] == 'HDP' %}
{% set gobblin_package = 'gobblin-distribution-' + gobblin_version + '-HDP.tar.gz' %}
{% else %}
{% set gobblin_package = 'gobblin-distribution-' + gobblin_version + '-CDH.tar.gz' %}
{% endif %}

{% set pnda_modules_version = pillar['platform_gobblin_modules']['release_version'] %}
{% set pnda_modules_package = 'gobblin-PNDA-' + pnda_modules_version + '.tar.gz' %}

{% set pnda_home = pillar['pnda']['homedir'] %}
{% set pnda_user  = pillar['pnda']['user'] %}
{% set gobblin_real_dir = pnda_home + '/gobblin-' + gobblin_version %}
{% set gobblin_link_dir = pnda_home + '/gobblin' %}
{% set pnda_modules_dir = pnda_home + '/gobblin-' + gobblin_version + '/pnda-modules' %}

{% set namenode = salt['pnda.hadoop_namenode']() %}

{%- set kafka_brokers = [] -%}
{%- for ip in salt['pnda.kafka_brokers_hosts']() -%}
{%-   do kafka_brokers.append(ip + ':9092') -%}
{%- endfor -%}

{% set pnda_master_dataset_location = pillar['pnda']['master_dataset']['directory'] %}
{% set pnda_kite_dataset_uri = "dataset:" + namenode + pnda_master_dataset_location %}

{% set pnda_quarantine_dataset_location = pillar['pnda']['master_dataset']['quarantine_directory'] %}
{% set pnda_quarantine_kite_dataset_uri = "dataset:" + namenode + pnda_quarantine_dataset_location %}

{% set pnda_compacted_dataset_location = pillar['pnda']['master_dataset']['compaction_directory'] %}
{% set perform_compaction = salt['pillar.get']('dataset_compaction:compaction', False) %}

{% if perform_compaction %}
{% set compaction_pattern = salt['pillar.get']('dataset_compaction:pattern', 'd') %}
{%- endif %}

{% set gobblin_hdfs_work_dir = '/user/' + pnda_user + '/gobblin/work' %}

{% if grains['hadoop.distro'] == 'HDP' %}
{% set hadoop_home_bin = '/usr/hdp/current/hadoop-client/bin/' %}
{% else %}
{% set hadoop_home_bin = '/opt/cloudera/parcels/CDH/bin' %}
{% endif %}

{% set features = salt['pillar.get']('features', []) %}

gobblin-create_gobblin_version_directory:
  file.directory:
    - name: {{ gobblin_real_dir }}
    - makedirs: True

gobblin-dl-and-extract:
  archive.extracted:
    - name: {{ gobblin_real_dir }}
    - source: {{ packages_server }}/{{ gobblin_package }}
    - source_hash: {{ packages_server }}/{{ gobblin_package }}.sha512.txt
    - archive_format: tar
    - tar_options: ''
    - if_missing: {{ gobblin_real_dir }}/gobblin-dist
    - require:
      - file: gobblin-create_gobblin_version_directory

pnda_modules-dl-and-extract:
  archive.extracted:
    - name: {{ pnda_modules_dir }}
    - source: {{ packages_server }}/{{ pnda_modules_package }}
    - source_hash: {{ packages_server }}/{{ pnda_modules_package }}.sha512.txt
    - archive_format: tar
    - tar_options: ''

pnda_modules-copy-to-gobblin-lib:
  cmd.run:
    - name: cp {{ pnda_modules_dir }}/* {{ gobblin_real_dir }}/gobblin-dist/lib

gobblin-create_link:
  file.symlink:
    - name: {{ gobblin_link_dir }}
    - target: {{ gobblin_real_dir }}
    - require:
      - archive: gobblin-dl-and-extract

gobblin-update_gobblin_reference_configuration_file:
  file.replace:
    - name: {{ gobblin_real_dir }}/gobblin-dist/conf/gobblin-mapreduce.properties
    - pattern: '^fs.uri=hdfs://localhost:8020$'
    - repl: 'fs.uri={{ namenode }}'
    - require:
      - archive: gobblin-dl-and-extract

gobblin-update_gobblin_mapreduce_sh_file:
  file.replace:
    - name: {{ gobblin_real_dir }}/gobblin-dist/bin/gobblin-mapreduce.sh
    - pattern: 'data-2.6.0.jar'
    - repl: 'data-11.0.0.jar'
    - require:
      - archive: gobblin-dl-and-extract

gobblin-create_gobblin_jobs_directory:
  file.directory:
    - name: {{ gobblin_link_dir }}/configs
    - makedirs: True

gobblin-install_gobblin_pnda_job_file:
  file.managed:
    - name: {{ gobblin_link_dir }}/configs/mr.pull
    - source: salt://gobblin/templates/mr.pull.tpl
    - template: jinja
    - context:
      namenode: {{ namenode }}
      quarantine_kite_dataset_uri: {{ pnda_quarantine_kite_dataset_uri }}
      kafka_brokers: {{ kafka_brokers }}
      max_mappers: {{ flavor_cfg.max_mappers }}
      master_dataset_location: {{ pnda_master_dataset_location }}
    - require:
      - file: gobblin-create_gobblin_jobs_directory

{% if perform_compaction %}
gobblin-install_gobblin_pnda_compaction_job_file:
  file.managed:
    - name: {{ gobblin_link_dir }}/configs/mr.compact
    - source: salt://gobblin/templates/mr.compact.tpl
    - template: jinja
    - context:
      namenode: {{ namenode }}
      compacted_dataset_location: {{ pnda_compacted_dataset_location }}
      master_dataset_location: {{ pnda_master_dataset_location }}
      max_mappers: {{ flavor_cfg.max_mappers }}
    - require:
      - file: gobblin-create_gobblin_jobs_directory
{%- endif %}

gobblin-create_gobblin_logs_directory:
  file.directory:
    - name: /var/log/pnda/gobblin
    - user: {{ pnda_user }}
    - makedirs: True

gobblin-create_gobblin_logs_file:
  file.managed:
    - name: /var/log/pnda/gobblin/gobblin-current.log
    - user: pnda
    - group: pnda
    - mode: 0644

gobblin-install_gobblin_service_script:
  file.managed:
    - name: /usr/lib/systemd/system/gobblin.service
    - source: salt://gobblin/templates/gobblin.service.tpl
    - template: jinja
    - context:
      gobblin_directory_name: {{ gobblin_link_dir }}/gobblin-dist
      gobblin_user: {{ pnda_user }}
      gobblin_work_dir: {{ gobblin_hdfs_work_dir }}
      gobblin_job_file: {{ gobblin_link_dir }}/configs/mr.pull
      hadoop_home_bin: {{ hadoop_home_bin }}

{% if perform_compaction %}
gobblin-install_gobblin_compact_service_script:
  file.managed:
    - name: /usr/lib/systemd/system/gobblin-compact.service
    - source: salt://gobblin/templates/gobblin-compact.service.tpl
    - template: jinja
    - context:
      gobblin_directory_name: {{ gobblin_link_dir }}/gobblin-dist
      gobblin_user: {{ pnda_user }}
      gobblin_work_dir: {{ gobblin_hdfs_work_dir }}
      gobblin_job_file: {{ gobblin_link_dir }}/configs/mr.compact
      hadoop_home_bin: {{ hadoop_home_bin }}
{%- endif %}

gobblin-systemctl_reload:
  cmd.run:
    - name: /bin/systemctl daemon-reload

gobblin-add_gobblin_crontab_entry:
  cron.present:
    - identifier: GOBBLIN
    - name: /bin/systemctl start gobblin
    - user: root
    - minute: 0,30
    - require:
      - file: gobblin-install_gobblin_service_script

{% if perform_compaction %}
gobblin-add_gobblin_compact_crontab_entry:
  cron.present:
    - identifier: GOBBLIN-COMPACT
    - name: /bin/systemctl start gobblin-compact
    - user: root
{% if compaction_pattern == 'H' %}
    - minute: 0
{% elif compaction_pattern == 'd' %}
    - minute: 0
    - hour: 1
{% elif compaction_pattern == 'M' %}
    - minute: 0
    - hour: 1
    - daymonth: 1
{% elif compaction_pattern == 'Y' %}
    - minute: 0
    - hour: 1
    - daymonth: 1
    - month: 1
{% endif %}
    - require:
      - file: gobblin-install_gobblin_compact_service_script
{%- endif %}
