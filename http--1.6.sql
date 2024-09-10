-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION http" to load this file. \quit
CREATE DOMAIN http_method AS text;
CREATE DOMAIN content_type AS text
CHECK (
    VALUE ~ '^\S+\/\S+'
);

CREATE TYPE http_header AS (
    field VARCHAR,
    value VARCHAR
);

CREATE TYPE http_response AS (
    status INTEGER,
    content_type VARCHAR,
    headers http_header[],
    content VARCHAR
);

CREATE TYPE http_request AS (
    method http_method,
    uri VARCHAR,
    headers http_header[],
    content_type VARCHAR,
    content VARCHAR
);

CREATE FUNCTION http_set_curlopt (curlopt VARCHAR, value VARCHAR)
    RETURNS boolean
    AS 'MODULE_PATHNAME', 'http_set_curlopt'
    LANGUAGE 'c';

CREATE FUNCTION http_reset_curlopt ()
    RETURNS boolean
    AS 'MODULE_PATHNAME', 'http_reset_curlopt'
    LANGUAGE 'c';

CREATE FUNCTION http_list_curlopt ()
    RETURNS TABLE(curlopt text, value text)
    AS 'MODULE_PATHNAME', 'http_list_curlopt'
    LANGUAGE 'c';

CREATE FUNCTION http_header (field VARCHAR, value VARCHAR)
    RETURNS http_header
    AS $$ SELECT $1, $2 $$
    LANGUAGE 'sql';

CREATE FUNCTION http(request @extschema@.http_request)
    RETURNS http_response
    AS 'MODULE_PATHNAME', 'http_request'
    LANGUAGE 'c';

CREATE FUNCTION http_get(uri VARCHAR)
    RETURNS http_response
    AS $$ SELECT @extschema@.http(('GET', $1, NULL, NULL, NULL)::@extschema@.http_request) $$
    LANGUAGE 'sql';

CREATE FUNCTION http_post(uri VARCHAR, content VARCHAR, content_type VARCHAR)
    RETURNS http_response
    AS $$ SELECT @extschema@.http(('POST', $1, NULL, $3, $2)::@extschema@.http_request) $$
    LANGUAGE 'sql';

CREATE FUNCTION http_put(uri VARCHAR, content VARCHAR, content_type VARCHAR)
    RETURNS http_response
    AS $$ SELECT @extschema@.http(('PUT', $1, NULL, $3, $2)::@extschema@.http_request) $$
    LANGUAGE 'sql';

CREATE FUNCTION http_patch(uri VARCHAR, content VARCHAR, content_type VARCHAR)
    RETURNS http_response
    AS $$ SELECT @extschema@.http(('PATCH', $1, NULL, $3, $2)::@extschema@.http_request) $$
    LANGUAGE 'sql';

CREATE FUNCTION http_delete(uri VARCHAR)
    RETURNS http_response
    AS $$ SELECT @extschema@.http(('DELETE', $1, NULL, NULL, NULL)::@extschema@.http_request) $$
    LANGUAGE 'sql';

CREATE FUNCTION http_delete(uri VARCHAR, content VARCHAR, content_type VARCHAR)
    RETURNS http_response
    AS $$ SELECT @extschema@.http(('DELETE', $1, NULL, $3, $2)::@extschema@.http_request) $$
    LANGUAGE 'sql';

CREATE FUNCTION http_head(uri VARCHAR)
    RETURNS http_response
    AS $$ SELECT @extschema@.http(('HEAD', $1, NULL, NULL, NULL)::@extschema@.http_request) $$
    LANGUAGE 'sql';

CREATE FUNCTION urlencode(string VARCHAR)
    RETURNS TEXT
    AS 'MODULE_PATHNAME'
    LANGUAGE 'c'
    IMMUTABLE STRICT;

CREATE FUNCTION urlencode(string BYTEA)
    RETURNS TEXT
    AS 'MODULE_PATHNAME'
    LANGUAGE 'c'
    IMMUTABLE STRICT;

CREATE FUNCTION urlencode(data JSONB)
    RETURNS TEXT
    AS 'MODULE_PATHNAME', 'urlencode_jsonb'
    LANGUAGE 'c'
    IMMUTABLE STRICT;

CREATE FUNCTION http_get(uri VARCHAR, data JSONB)
    RETURNS http_response
    AS $$
        SELECT @extschema@.http(('GET', $1 || '?' || @extschema@.urlencode($2), NULL, NULL, NULL)::@extschema@.http_request)
    $$
    LANGUAGE 'sql';

CREATE FUNCTION http_post(uri VARCHAR, data JSONB)
    RETURNS http_response
    AS $$
        SELECT @extschema@.http(('POST', $1, NULL, 'application/x-www-form-urlencoded', @extschema@.urlencode($2))::@extschema@.http_request)
    $$
    LANGUAGE 'sql';

CREATE FUNCTION text_to_bytea(data TEXT)
    RETURNS BYTEA
    AS 'MODULE_PATHNAME', 'text_to_bytea'
    LANGUAGE 'c'
    IMMUTABLE STRICT;

CREATE FUNCTION bytea_to_text(data BYTEA)
    RETURNS TEXT
    AS 'MODULE_PATHNAME', 'bytea_to_text'
    LANGUAGE 'c'
    IMMUTABLE STRICT;

CREATE TABLE @extschema@._http_crawl_plans(
    id serial primary key,
    name text not null
);

CREATE INDEX ON @extschema@._http_crawl_plans(name);

CREATE TABLE @extschema@._http_pages(
    id serial primary key,

    req_method http_method,
    req_uri text,
    req_headers http_header[],
    req_content_type text,
    req_content text,

    resp_status integer,
    resp_content_type text,
    resp_headers http_header[],
    resp_content text,

    metadata jsonb,
    fk_crawl_plan_id integer references @extschema@._http_crawl_plans(id)
);

CREATE FUNCTION sp_create_crawl_plan(plan_name text, variadic urls text[])
    RETURNS integer LANGUAGE SQL AS $$
    WITH plan AS (
        -- Insert a new crawl plan and return its id
        INSERT INTO @extschema@._http_crawl_plans(name)
        VALUES (plan_name)
        RETURNING id
    )
    -- Insert the URLs into the pages table
    INSERT INTO @extschema@._http_pages(req_method, req_uri, fk_crawl_plan_id)
    SELECT 'GET', url, (SELECT id FROM plan)
    FROM unnest(urls) AS url
    RETURNING id;
$$;

CREATE FUNCTION http_get_log(uri VARCHAR, logged boolean default true, metadata jsonb default null)
    RETURNS http_response
AS $$
DECLARE
request http_request;
response http_response;
BEGIN
request := ('GET', uri, NULL, NULL, NULL)::@extschema@.http_request;
response := @extschema@.http(request);
IF logged THEN
        INSERT INTO @extschema@._http_pages (
            req_method, req_uri, req_headers, req_content_type, req_content,
            resp_status, resp_content_type, resp_headers, resp_content,
            metadata
        )
        VALUES (
        (request).method, (request).uri, (request).headers, (request).content_type, (request).content,
        (response).status, (request).content_type, (request).headers, (request).content,
        metadata
        );
END IF;
RETURN response;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION http_many(request @extschema@.http_request[])
    RETURNS @extschema@.http_response[]
AS 'MODULE_PATHNAME', 'http_request_many'
    LANGUAGE 'c';

CREATE FUNCTION http_get_many(uri VARCHAR[])
    RETURNS @extschema@.http_response[]
    AS $$
SELECT http_many(array_agg(ROW('GET', u, NULL, NULL, NULL)::@extschema@.http_request))
FROM unnest($1) AS u
    $$ LANGUAGE sql;
