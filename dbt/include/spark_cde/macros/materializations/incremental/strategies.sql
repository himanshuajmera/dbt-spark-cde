{% macro get_insert_overwrite_sql(source_relation, target_relation) %}

    {%- set dest_columns = adapter.get_columns_in_relation(target_relation) -%}
    {%- set dest_cols_csv = dest_columns | map(attribute='quoted') | join(', ') -%}
    insert overwrite table {{ target_relation }}
    {{ partition_cols(label="partition") }}
    select {{dest_cols_csv}} from {{ source_relation.include(database=false, schema=false) }}

{% endmacro %}


{% macro get_insert_into_sql(source_relation, target_relation) %}

    {%- set dest_columns = adapter.get_columns_in_relation(target_relation) -%}
    {%- set dest_cols_csv = dest_columns | map(attribute='quoted') | join(', ') -%}
    insert into table {{ target_relation }}
    select {{dest_cols_csv}} from {{ source_relation.include(database=false, schema=false) }}

{% endmacro %}


{% macro spark_cde__get_merge_sql(target, source, unique_key, dest_columns, predicates=none) %}
  {# skip dest_columns, use merge_update_columns config if provided, otherwise use "*" #}
  {%- set predicates = [] if predicates is none else [] + predicates -%}
  {%- set update_columns = config.get("merge_update_columns") -%}

  {% if unique_key %}
      {% if unique_key is sequence and unique_key is not mapping and unique_key is not string %}
          {% for key in unique_key %}
              {% set this_key_match %}
                  DBT_INTERNAL_SOURCE.{{ key }} = DBT_INTERNAL_DEST.{{ key }}
              {% endset %}
              {% do predicates.append(this_key_match) %}
          {% endfor %}
      {% else %}
          {% set unique_key_match %}
              DBT_INTERNAL_SOURCE.{{ unique_key }} = DBT_INTERNAL_DEST.{{ unique_key }}
          {% endset %}
          {% do predicates.append(unique_key_match) %}
      {% endif %}
  {% else %}
      {% do predicates.append('FALSE') %}
  {% endif %}

  {{ sql_header if sql_header is not none }}

  merge into {{ target }} as DBT_INTERNAL_DEST
      using {{ source.include(schema=false) }} as DBT_INTERNAL_SOURCE
      on {{ predicates | join(' and ') }}

      when matched then update set
        {% if update_columns -%}{%- for column_name in update_columns %}
            {{ column_name }} = DBT_INTERNAL_SOURCE.{{ column_name }}
            {%- if not loop.last %}, {%- endif %}
        {%- endfor %}
        {%- else %} * {% endif %}

      when not matched then insert *
{% endmacro %}


{% macro dbt_spark_get_incremental_sql(strategy, source, target, unique_key) %}
  {%- if strategy == 'append' -%}
    {#-- insert new records into existing table, without updating or overwriting #}
    {{ get_insert_into_sql(source, target) }}
  {%- elif strategy == 'insert_overwrite' -%}
    {#-- insert statements don't like CTEs, so support them via a temp view #}
    {{ get_insert_overwrite_sql(source, target) }}
  {%- elif strategy == 'merge' -%}
  {#-- merge all columns with databricks delta - schema changes are handled for us #}
    {{ get_merge_sql(target, source, unique_key, dest_columns=none, predicates=none) }}
  {%- else -%}
    {% set no_sql_for_strategy_msg -%}
      No known SQL for the incremental strategy provided: {{ strategy }}
    {%- endset %}
    {%- do exceptions.raise_compiler_error(no_sql_for_strategy_msg) -%}
  {%- endif -%}

{% endmacro %}
