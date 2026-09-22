-- Scratch template for data modelling the fact_incident table based on stg.pp
DROP TABLE IF EXISTS rep.fact_incident;
CREATE TABLE rep.fact_incident (
	pk_incident text PRIMARY KEY,
	incident_no text,
	call_type text,
	call_source text,
	creation_date_timestamp timestamp,
	modification_date_timestamp timestamp,
	crime_type text,
	date_occurred date,
	time_occurred time,
	date_reported date,
	time_received time,
	time_dispatched time,
	finalisation_status text,
	incident_village text,
	section text,
	location text,
	location_of_incident_street text,
	location_of_incident_other text,
	flag_alcohol boolean,
	--flag_seniorleadership_tag boolean,
	flag_domestic boolean,
	flag_narcotics boolean,
	narcotics_type text,
	flag_mental_health boolean,
--	flag_firearm boolean,
	flag_significant boolean,
	loaded_at timestamp NOT NULL
);

INSERT INTO rep.fact_incident(
pk_incident ,
	incident_no ,
	call_type ,
	call_source ,
	creation_date_timestamp ,
	modification_date_timestamp ,
	crime_type ,
	date_occurred ,
	time_occurred ,
	date_reported ,
	time_received ,
	time_dispatched ,
	finalisation_status ,
	incident_village ,
	section ,
	location ,
	location_of_incident_street ,
	location_of_incident_other ,
	flag_alcohol ,
	flag_domestic ,
	flag_narcotics ,
	narcotics_type ,
	flag_mental_health ,
	flag_significant ,
	loaded_at)

SELECT 
	DISTINCT ON(__pkeypolicepro_id)
	__pkeypolicepro_id as pk_incident,
	bltr as incident_no,
	call_type,
	call_source,
	creation_date_timestamp::timestamp,
	modification_date_timestamp::timestamp,
	crime_type,
	stg.try_date(date_occurred) as date_occurred,
	stg.try_time(time_occurred) as time_occurred,
	stg.try_date(date) as date_reported,
	stg.try_time(time_received) as time_received,
	stg.try_time(time_dispatched) as time_dispatched,
	finalisation_status,
	village as incident_village,
	section,
	location,
	location_of_incident_street,
	location_of_incident_other,
	case when alcohol is not null then TRUE
		else FALSE end as flag_alcohol,
	case when domestic is not null then TRUE
		else FALSE end as flag_domestic,
	case when narcotics_flag is not null then TRUE
		ELSE FALSE end as flag_narcotics,
	narcotics_type,
	case when mental_health is not null then TRUE
		else FALSE end as flag_mental_health,
	case when significant is not null then TRUE 
		else FALSE end as flag_significant,
	loaded_at

FROM stg.pp
WHERE __pkeypolicepro_id is not null
ORDER  BY "__pkeypolicepro_id",
          stg.try_ts(modification_date_timestamp) DESC NULLS LAST,
          loaded_at DESC;
;

