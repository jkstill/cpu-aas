
-- synaas.sql
-- synthetic AAS (average active sessions)
-- the AAS value in dba_hist_sysmetric_history does not seem reliable
--

set linesize 200 trimspool on
set pagesize 60

col sample_time format a35
col begin_interval_time format a35
col end_interval_time format a35

define CSVOUT=''

col u_pagesize new_value u_pagesize noprint
col u_feedstate new_value u_feedstate noprint
col u_spoolfile new_value u_spoolfile noprint
col RPTOUT new_value RPTOUT noprint

set term off feed off echo off pause off timing off

select decode('&&CSVOUT','--','','--') RPTOUT from dual;

select 
	&&RPTOUT 'synaas.txt' u_spoolfile
	&&CSVOUT 'synaas.csv' u_spoolfile
from dual;

select decode('&&CSVOUT','--',60,50000) u_pagesize from dual;
select decode('&&CSVOUT','--','on','off') u_feedstate from dual;

set term off feed off echo off 
col gethead noprint new_value gethead

spool &u_spoolfile

-- heading

select  &&RPTOUT null gethead
	&&CSVOUT q'[snap_id,instance_number,begin_interval_time,end_interval_time,db_time,elapsed_time,aas]' gethead
from dual;

prompt &&gethead

set pagesize &&u_pagesize
set head off term on
set feed &&u_feedstate head &&u_feedstate

btitle off
ttitle off

with data as (
	select distinct h.snap_id , h.instance_number
		, s.begin_interval_time
		, s.end_interval_time
		, count(*) over (partition by h.snap_id, h.instance_number) * 10 db_time
		, (extract( day from (s.end_interval_time - s.begin_interval_time) )*24*60*60)+
			(extract( hour from (s.end_interval_time - s.begin_interval_time) )*60*60)+
			(extract( minute from (s.end_interval_time - s.begin_interval_time) )*60)+
			(extract( second from (s.end_interval_time - s.begin_interval_time))) 
		elapsed_time
	from dba_hist_active_sess_history h
	join dba_hist_snapshot s on s.snap_id = h.snap_id
		and s.instance_number = h.instance_number
	where (
		( h.session_state = 'WAITING' and h.wait_class not in ('Idle') )
		or
		h.session_state = 'ON CPU'
	)
	order by 1,2
)
select 
	&&RPTOUT snap_id
	&&RPTOUT , instance_number
	&&RPTOUT , begin_interval_time
	&&RPTOUT , end_interval_time
	&&RPTOUT , db_time
	&&RPTOUT , elapsed_time
	&&RPTOUT , to_char(round(db_time / elapsed_time,1),'9990.9') aas
	&&CSVOUT snap_id
	&&CSVOUT || ',' || instance_number
	&&CSVOUT || ',' || begin_interval_time
	&&CSVOUT || ',' || end_interval_time
	&&CSVOUT || ',' || db_time
	&&CSVOUT || ',' || elapsed_time
	&&CSVOUT || ',' || to_char(round(db_time / elapsed_time,1),'9990.9')
from data d
order by snap_id, begin_interval_time, instance_number
/

spool off

ed &u_spoolfile

