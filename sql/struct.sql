CREATE EXTENSION http;

select http_struct(('GET', 'https://example.com', NULL, 'text/json', 'content')::http_request);
