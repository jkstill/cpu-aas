-- aas-hist-compare.sql
-- values from gv$sysmetric_history appear to be accurately transferred to dba_hist_sysmetric_history

set pagesize 60
set linesize 200 trimspool on


with gv_hist as (
   select  inst_id instance_number
      , begin_time
      , end_time
      , round(value,1) aas
   from gv$sysmetric_history
   where metric_name = 'Average Active Sessions'
   order by begin_time
),
dba_hist as (
   select  instance_number
      , begin_time
      , end_time
      , round(value,1) aas
   from dba_hist_sysmetric_history
   where metric_name = 'Average Active Sessions'
      and begin_time >= ( select min(begin_time) from gv$sysmetric_history)
   order by begin_time
)
select
   to_char(g.begin_time,'yyyy-mm-dd hh24:mi:ss') begin_time
   , to_char(g.end_time,'yyyy-mm-dd hh24:mi:ss') end_time
   , to_char(g.aas,'9990.9') aas_gv
   , to_char(d.aas,'9990.9') aas_d
from gv_hist g
join dba_hist d on d.instance_number = g.instance_number
   and d.begin_time = g.begin_time
order by g.begin_time
/
