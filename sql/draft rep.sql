

CREATE TABLE IF NOT EXISTS rep.fact_incident_charge (
	pk_incident_charge text PRIMARY KEY, -- __pkey_charge_id
	arrest_no text,
	creation_date_timestamp timestamp,
	created_by text,
	modification_date_timestamp timestamp,
	fk_incident text, -- _fkeypolicepro_id
	fk_law text, -- _fkeynyslaw_id with DIM to be extracted
	fk_arrest text, -- _fkeyarrest_id to be extracted
	code text, -- Consider what can be brought in via DIM instead
	class text,
	offense text,
	attempt boolean,
	judge text,
	disp_date date,
	disp_sentence text,
	conviction boolean,
	counts numeric,
	loaded_at timestamp NOT NULL,
	transformed_at timestamp NOT NULL DEFAULT clock_timestamp()
);


-- For a table that already existed before transformed_at was added.
ALTER TABLE rep.fact_incident_charge
    ADD COLUMN IF NOT EXISTS transformed_at timestamp NOT NULL DEFAULT clock_timestamp();


INSERT INTO rep.fact_incident_charge (
	pk_incident_charge, -- __pkey_charge_id
	arrest_no ,
	creation_date_timestamp ,
	created_by ,
	modification_date_timestamp ,
	fk_incident , -- _fkeypolicepro_id
	fk_law , -- _fkeynyslaw_id with DIM to be extracted
	fk_arrest , -- _fkeyarrest_id to be extracted
	code , -- Consider what can be brought in via DIM instead
	class ,
	offense ,
	attempt ,
	judge ,
	disp_date ,
	disp_sentence ,
	conviction ,
	counts ,
	loaded_at  ,
	transformed_at
) SELECT
	__pkeycharge_id as pk_incident_charge,
	"arrest_#" as arrest_no,
	stg.try_ts(creation_timestamp) as creation_date_timestamp,
	created_by,
	stg.try_ts(modification_timestamp) as modification_date_timestamp,
	_fkeypolicepro_id as fk_incident,
	_fkeynyslaw_id as fk_law,
	_fkeyarrest_id as fk_arrest,
	code,
	class,
	offense,
	case when trim(attempt) is not null then TRUE else FALSE end as attempt,
	judge,
	stg.try_date(disp_date) as disp_date,
	disp_sentence,
	case when trim(conviction) is not null then TRUE else FALSE end as conviction,
	stg.try_numeric(counts) as counts,
	loaded_at,
	clock_timestamp() as transformed_at
FROM (
	SELECT DISTINCT ON (__pkeycharge_id) *
	FROM stg.charges
	WHERE  __pkeycharge_id is not null
	ORDER BY __pkeycharge_id, 
		stg.try_ts(modification_timestamp) DESC NULLS LAST,
		loaded_at DESC
	) 

	