{% macro drop_target_schema() %}
  {% set database = target.database | upper %}
  {% set schema = target.schema | upper %}

  {% do run_query('drop schema if exists ' ~ database ~ '.' ~ schema ~ ' cascade') %}
  {% do run_query('create schema ' ~ database ~ '.' ~ schema) %}

  {{ log('Reset schema ' ~ database ~ '.' ~ schema, info=True) }}
{% endmacro %}
