CREATE EXTENSION http;

-- select http_struct(('GET', 'https://example.com', NULL, 'text/json', 'content')::http_request);

SELECT status, content_type FROM http_struct_get('https://httpbin.org/status/202');
