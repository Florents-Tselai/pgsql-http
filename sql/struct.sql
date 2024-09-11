CREATE EXTENSION http;

select http_struct(('GET', '"example.com"', NULL, NULL, NULL)::http_request);