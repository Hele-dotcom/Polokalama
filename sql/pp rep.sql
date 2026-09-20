-- Scratch template for data modelling the fact_incident table based on stg.pp

CREATE TABLE rep.fact_incident (
	pk_incident text PRIMARY KEY,
	incident_no text,
	call_type text,
	creation_date_timestamp timestamp,
	crime_type text,
	crime_type_2 text,
	crime_type_3 text,
	date_occurred date,
	time_occurred time,
	date_reported date,
	time_reported time,
	time_dispatched time,
	domestic text,
	finalisation_status text,
	incident_village text,
	modification_date_timestamp timestamp,
	loaded_at timestamp NOT NULL,
)


SELECT 
	__pkeypolicepro_id as pk_incident,
	bltr as incident_no,
	date_occurred as date_occurred,
	


FROM stg.pp

;

