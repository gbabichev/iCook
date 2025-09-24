<?php
/*

# iCook REST API Documentation

This API powers the iCook SwiftUI recipes app. It is designed for a LAN deployment with simple JSON CRUD endpoints and image uploads.

## Base URL
- Script path: `https://<host>:<port>/api.php`
- Most hosts require the `?route=` fallback for path routing:
  - Example: `https://<host>:<port>/api.php?route=/categories`
- If your server supports PATH_INFO, you can also call: `https://<host>:<port>/api.php/categories`

> **Tip**: All examples below use the `?route=` style for maximum compatibility.

## Content Types
- **JSON requests**: `Content-Type: application/json`
- **File uploads**: `multipart/form-data` with field `file`
- **Responses**: `application/json; charset=utf-8`

## Health Check
**GET** `/` or `/api` or `/api.php`
```json
{ "status": "ok", "time": "2025-09-16T12:34:56Z" }
```

---
## Categories

### List Categories
**GET** `/categories`
Query params:
- `q` *(optional)* — search by name (substring match)
- `page` *(default: 1)* — 1-based page index
- `limit` *(default: 100, max: 100)* — page size

**Example**
```bash
curl "https://<host>:<port>/api.php?route=/categories&q=des&page=1&limit=25"
```
**200 OK**
```json
{ "data": [{"id":1,"name":"Desserts"}], "page":1, "limit":25, "total": 12, "query":"des" }
```

### Get Category by ID
**GET** `/categories/{id}`
```bash
curl "https://<host>:<port>/api.php?route=/categories/1"
```
**200 OK**
```json
{ "id": 1, "name": "Desserts" }
```
**404 Not Found**
```json
{ "error": "Category not found" }
```

### Create Category
**POST** `/categories`
**Headers**: `Content-Type: application/json`
**Body**
```json
{ "name": "Soups" }
```
**201 Created**
```json
{ "id": 2, "name": "Soups" }
```
**409 Conflict** — duplicate name (if you add a UNIQUE index on `name`)
```json
{ "error": "Category name already exists" }
```

### Update Category
**PUT** `/categories/{id}`
```bash
curl -X PUT "https://<host>:<port>/api.php?route=/categories/2" \
  -H "Content-Type: application/json" \
  -d '{"name":"Broths & Soups"}'
```
**200 OK**
```json
{ "id": 2, "name": "Broths & Soups" }
```

### Delete Category
**DELETE** `/categories/{id}`
```bash
curl -X DELETE "https://<host>:<port>/api.php?route=/categories/2"
```
**200 OK**
```json
{ "deleted": 2 }
```

---
## Recipes

### List Recipes
**GET** `/recipes`
Query params:
- `id` *(optional)* — fetch a single recipe by id
- `category_id` *(optional)* — filter by category
- `q` *(optional)* — search by name, details, or ingredients
- `page` *(default: 1)*, `limit` *(default: 50, max: 100)*

**Examples**
```bash
# all (paged)
curl "https://<host>:<port>/api.php?route=/recipes&page=1&limit=50"
# by id
curl "https://<host>:<port>/api.php?route=/recipes&id=1"
# by category
curl "https://<host>:<port>/api.php?route=/recipes&category_id=1"
# search
curl "https://<host>:<port>/api.php?route=/recipes&q=tomato"
```
**200 OK** (list)
```json
{ "data": [{
  "id": 1,
  "category_id": 1,
  "name": "Tomato Soup",
  "recipe_time": 30,
  "details": "# Tomato Soup\n- Tomatoes\n- Onion\n- Garlic",
  "image": "/uploads/abc.jpg",
  "ingredients": ["tomatoes", "onion", "garlic", "olive oil", "salt", "pepper"]
}], "page":1, "limit":50, "total": 1 }
```
**200 OK** (single)
```json
{ "id": 1, "category_id": 1, "name":"Tomato Soup", "recipe_time":30, "details":"...", "image":"/uploads/abc.jpg", "ingredients": ["tomatoes", "onion", "garlic", "olive oil", "salt", "pepper"] }
```

### Create Recipe
**POST** `/recipes`
**Headers**: `Content-Type: application/json`
**Body**
```json
{
  "category_id": 1,
  "name": "Pesto Pasta",
  "recipe_time": 20,
  "details": "## Ingredients\n- Pasta\n- Pesto",
  "image": "/uploads/abc123.jpg",
  "ingredients": ["pasta", "pesto", "parmesan cheese", "pine nuts"]
}
```
**201 Created**
```json
{ "id": 5, "category_id": 1, "name":"Pesto Pasta", "recipe_time":20, "details":"...", "image":"/uploads/abc123.jpg", "ingredients": ["pasta", "pesto", "parmesan cheese", "pine nuts"] }
```
**404 Not Found** — category doesn't exist
```json
{ "error": "Category not found" }
```

### Update Recipe
**PUT** `/recipes/{id}`
- Any subset of fields may be sent; unspecified fields remain unchanged.
```bash
curl -X PUT "https://<host>:<port>/api.php?route=/recipes/5" \
  -H "Content-Type: application/json" \
  -d '{"name":"Pesto Pasta (Creamy)", "recipe_time":25, "ingredients":["pasta", "pesto", "cream", "parmesan"]}'
```
**200 OK** → returns the full updated recipe.

### Delete Recipe
**DELETE** `/recipes/{id}`
```bash
curl -X DELETE "https://<host>:<port>/api.php?route=/recipes/5"
```
**200 OK**
```json
{ "deleted": 5 }
```

---
## Media Uploads

### Upload Image
**POST** `/media`
- `multipart/form-data`
- Field: **`file`** (the image)
- Allowed types: `image/jpeg`, `image/png`, `image/webp`
- Max size: **5MB** (configurable)

**Example**
```bash
curl -X POST "https://<host>:<port>/api.php?route=/media" \
  -F "file=@/path/to/picture.jpg"
```
**201 Created**
```json
{
  "path": "/uploads/abc123.jpg",
  "filename": "abc123.jpg",
  "mime": "image/jpeg",
  "bytes": 123456,
  "width": 1024,
  "height": 768
}
```
Store the returned `path` in the recipe's `image` field.

---
## Errors & Status Codes
- `200 OK` — successful read/update/delete
- `201 Created` — successful creation (returns the created resource)
- `400 Bad Request` — validation error or malformed JSON
- `404 Not Found` — resource doesn't exist
- `409 Conflict` — duplicate name (categories)
- `413 Payload Too Large` — image exceeds size limit
- `415 Unsupported Media Type` — wrong `Content-Type`
- `500 Internal Server Error` — unexpected failure

**Error format**
```json
{ "error": "Message", "detail": "Optional detail" }
```

---
## Configuration Notes
- Upload dir: `uploads/` next to `api.php`. Must be writable by PHP and served at URL prefix `/uploads`.
- DB credentials are defined at the top of `api.php`.
- CORS headers are commented out; enable if calling from a browser app.

*/


// iCook REST API (READ-FIRST)
// Update DB credentials as needed
$DB_HOST = '192.168.20.20';
$DB_NAME = 'iCook';     // change to your DB name
$DB_USER = 'iCook';        // change
$DB_PASS = 'helloWorld1!';            // change
$DB_CHARSET = 'utf8mb4';

$UPLOAD_DIR = __DIR__ . '/uploads';                 // filesystem path
$UPLOAD_URL_PREFIX = '/uploads';                    // URL path prefix served by your web server
$MAX_UPLOAD_BYTES = 5 * 1024 * 1024;                // 5MB limit
$ALLOWED_MIME = ['image/jpeg','image/png','image/webp'];

header('Content-Type: application/json; charset=utf-8');
// For native apps on LAN, CORS typically not required. If you need it for testing in browser, uncomment:
// header('Access-Control-Allow-Origin: *');
// header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
// header('Access-Control-Allow-Headers: Content-Type, Authorization');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

function json_ok($data, int $code = 200): void {
    http_response_code($code);
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function json_err(string $message, int $code = 400, array $extra = []): void {
    http_response_code($code);
    echo json_encode(['error' => $message] + $extra, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function read_json_body(): array {
    $raw = file_get_contents('php://input');
    if ($raw === false || $raw === '') return [];
    $data = json_decode($raw, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        json_err('Invalid JSON body', 400, ['detail' => json_last_error_msg()]);
    }
    return is_array($data) ? $data : [];
}

function ensure_upload_dir(string $dir): void {
    if (!is_dir($dir)) {
        if (!mkdir($dir, 0755, true) && !is_dir($dir)) {
            json_err('Failed to create upload directory');
        }
    }
    if (!is_writable($dir)) {
        json_err('Upload directory is not writable');
    }
}

function random_filename(string $ext): string {
    try {
        return bin2hex(random_bytes(16)) . $ext;
    } catch (Throwable $e) {
        return uniqid('', true) . $ext;
    }
}

function parse_ingredients($ingredients): ?string {
    if ($ingredients === null) return null;
    if (is_string($ingredients)) {
        // If it's already a JSON string, validate it
        $decoded = json_decode($ingredients, true);
        if (json_last_error() === JSON_ERROR_NONE && is_array($decoded)) {
            // Validate array contains only strings
            foreach ($decoded as $ingredient) {
                if (!is_string($ingredient)) {
                    json_err('Ingredients must be an array of strings');
                }
            }
            return $ingredients;
        }
        json_err('Invalid ingredients JSON format');
    }
    if (is_array($ingredients)) {
        // Validate array contains only strings
        foreach ($ingredients as $ingredient) {
            if (!is_string($ingredient)) {
                json_err('Ingredients must be an array of strings');
            }
        }
        return json_encode($ingredients, JSON_UNESCAPED_UNICODE);
    }
    json_err('Ingredients must be an array of strings or valid JSON array string');
}

function format_recipe_row($row): array {
    if (isset($row['ingredients']) && $row['ingredients']) {
        $row['ingredients'] = json_decode($row['ingredients'], true) ?: [];
    } else {
        $row['ingredients'] = [];
    }
    return $row;
}

// PDO connection
try {
    $dsn = "mysql:host={$DB_HOST};dbname={$DB_NAME};charset={$DB_CHARSET}";
    $pdo = new PDO($dsn, $DB_USER, $DB_PASS, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
} catch (Throwable $e) {
    json_err('Database connection failed', 500, ['detail' => $e->getMessage()]);
}

// Simple router
$rawPath = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$scriptName = $_SERVER['SCRIPT_NAME'] ?? '';
$pathInfo   = $_SERVER['PATH_INFO']   ?? '';
$method     = $_SERVER['REQUEST_METHOD'] ?? 'GET';

// Prefer PATH_INFO if the server provides it (some hosts disable it)
if ($pathInfo !== '') {
    $path = $pathInfo;
} else {
    $path = $rawPath;
    // If the URL looks like /api.php/... strip the script segment so we get "/..."
    if ($scriptName && str_starts_with($path, $scriptName)) {
        $path = substr($path, strlen($scriptName));
        if ($path === false) { $path = '/'; }
        if ($path === '') { $path = '/'; }
    }
}

// Allow a query fallback: /api.php?route=/categories
if (isset($_GET['route']) && is_string($_GET['route']) && $_GET['route'] !== '') {
    $path = '/' . ltrim($_GET['route'], '/');
}

$path = rtrim($path, '/');
if ($path === '') { $path = '/'; }

// Health check
if ($path === '/' || $path === '/api' || $path === '/api.php') {
    json_ok(['status' => 'ok', 'time' => date(DATE_ATOM)]);
}

// ---- POST /media (upload image) ----
if ($method === 'POST' && preg_match('#^/media$#', $path)) {
    try {
        // Expect multipart/form-data with field name "file"
        if (!isset($_FILES['file']) || !is_array($_FILES['file'])) {
            json_err('No file uploaded', 400);
        }
        $f = $_FILES['file'];
        if (($f['error'] ?? UPLOAD_ERR_OK) !== UPLOAD_ERR_OK) {
            $err = (int)$f['error'];
            $map = [
                UPLOAD_ERR_INI_SIZE => 'File too large (ini)',
                UPLOAD_ERR_FORM_SIZE => 'File too large (form)',
                UPLOAD_ERR_PARTIAL => 'Partial upload',
                UPLOAD_ERR_NO_FILE => 'No file',
                UPLOAD_ERR_NO_TMP_DIR => 'No temp dir',
                UPLOAD_ERR_CANT_WRITE => 'Disk write failed',
                UPLOAD_ERR_EXTENSION => 'Upload stopped by extension',
            ];
            json_err($map[$err] ?? 'Upload error', 400, ['code' => $err]);
        }
        $tmp = $f['tmp_name'];
        if (!is_uploaded_file($tmp)) {
            json_err('Invalid upload source');
        }
        $size = filesize($tmp);
        if ($size === false) { json_err('Cannot determine file size'); }
        global $MAX_UPLOAD_BYTES, $ALLOWED_MIME, $UPLOAD_DIR, $UPLOAD_URL_PREFIX;
        if ($size > $MAX_UPLOAD_BYTES) {
            json_err('File exceeds size limit', 413, ['max_bytes' => $MAX_UPLOAD_BYTES]);
        }

        $mime = function_exists('mime_content_type') ? mime_content_type($tmp) : null;
        if (!$mime || !in_array($mime, $ALLOWED_MIME, true)) {
            json_err('Unsupported file type', 415, ['mime' => $mime]);
        }
        $ext = ($mime === 'image/jpeg') ? '.jpg' : (($mime === 'image/png') ? '.png' : '.webp');

        // Basic image validation and get dimensions
        $info = @getimagesize($tmp);
        if ($info === false) {
            json_err('Invalid image file');
        }
        [$width, $height] = [$info[0], $info[1]];

        ensure_upload_dir($UPLOAD_DIR);
        $filename = random_filename($ext);
        $dest = $UPLOAD_DIR . '/' . $filename;
        if (!move_uploaded_file($tmp, $dest)) {
            json_err('Failed to save uploaded file', 500);
        }

        // Build URL/path to return (client will store in `image` column)
        $url = rtrim($UPLOAD_URL_PREFIX, '/') . '/' . $filename;
        http_response_code(201);
        json_ok([
            'path' => $url,
            'filename' => $filename,
            'mime' => $mime,
            'bytes' => $size,
            'width' => $width,
            'height' => $height,
        ], 201);
    } catch (Throwable $e) {
        json_err('Upload failed', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- POST /categories (create) ----
if ($method === 'POST' && preg_match('#^/categories$#', $path)) {
    try {
        // Only accept JSON
        $ctype = $_SERVER['CONTENT_TYPE'] ?? '';
        if (stripos($ctype, 'application/json') === false) {
            json_err('Content-Type must be application/json', 415);
        }
        $body = read_json_body();
        $name = trim((string)($body['name'] ?? ''));
        $icon = trim((string)($body['icon'] ?? ''));
        
        if ($name === '' || mb_strlen($name) > 100) {
            json_err('`name` is required (1-100 chars)');
        }
        if ($icon === '' || mb_strlen($icon) > 50) {
            json_err('`icon` is required (1-50 chars)');
        }
        
        $stmt = $pdo->prepare('INSERT INTO categories (name, icon) VALUES (?, ?)');
        $stmt->execute([$name, $icon]);
        $id = (int)$pdo->lastInsertId();
        http_response_code(201);
        json_ok(['id' => $id, 'name' => $name, 'icon' => $icon], 201);
    } catch (PDOException $e) {
        // Handle duplicate name if a UNIQUE constraint exists
        if ((int)$e->getCode() === 23000) {
            json_err('Category name already exists', 409);
        }
        json_err('Failed to create category', 500, ['detail' => $e->getMessage()]);
    } catch (Throwable $e) {
        json_err('Failed to create category', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- PUT /categories/{id} (update) ----
if ($method === 'PUT' && preg_match('#^/categories/(\d+)$#', $path, $m)) {
    try {
        $id = (int)$m[1];
        $ctype = $_SERVER['CONTENT_TYPE'] ?? '';
        if (stripos($ctype, 'application/json') === false) {
            json_err('Content-Type must be application/json', 415);
        }
        $body = read_json_body();
        
        $name = isset($body['name']) ? trim((string)$body['name']) : '';
        $icon = isset($body['icon']) ? trim((string)$body['icon']) : '';
        
        if ($name === '' || mb_strlen($name) > 100) {
            json_err('`name` is required (1-100 chars)');
        }
        if ($icon === '' || mb_strlen($icon) > 50) {
            json_err('`icon` is required (1-50 chars)');
        }
        
        // Ensure category exists
        $chk = $pdo->prepare('SELECT id FROM categories WHERE id = ?');
        $chk->execute([$id]);
        if (!$chk->fetch()) json_err('Category not found', 404);

        $stmt = $pdo->prepare('UPDATE categories SET name = ?, icon = ? WHERE id = ?');
        $stmt->execute([$name, $icon, $id]);
        json_ok(['id' => $id, 'name' => $name, 'icon' => $icon]);
    } catch (PDOException $e) {
        if ((int)$e->getCode() === 23000) {
            json_err('Category name already exists', 409);
        }
        json_err('Failed to update category', 500, ['detail' => $e->getMessage()]);
    } catch (Throwable $e) {
        json_err('Failed to update category', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- DELETE /categories/{id} (delete) ----
if ($method === 'DELETE' && preg_match('#^/categories/(\d+)$#', $path, $m)) {
    try {
        $id = (int)$m[1];
        $stmt = $pdo->prepare('DELETE FROM categories WHERE id = ?');
        $stmt->execute([$id]);
        if ($stmt->rowCount() === 0) json_err('Category not found', 404);
        json_ok(['deleted' => $id]);
    } catch (Throwable $e) {
        json_err('Failed to delete category', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- GET /categories and GET /categories/{id} ----
if ($method === 'GET' && preg_match('#^/categories(?:/(\d+))?$#', $path, $m)) {
    try {
        $id = isset($m[1]) ? (int)$m[1] : null;
        if ($id) {
            $stmt = $pdo->prepare('SELECT id, name, icon FROM categories WHERE id = ?');
            $stmt->execute([$id]);
            $row = $stmt->fetch();
            if (!$row) json_err('Category not found', 404);
            json_ok($row);
        }

        // Listing with optional search and pagination
        $q = isset($_GET['q']) ? trim((string)$_GET['q']) : '';
        $page = max(1, (int)($_GET['page'] ?? 1));
        $limit = min(100, max(1, (int)($_GET['limit'] ?? 100)));
        $offset = ($page - 1) * $limit;

        if ($q !== '') {
            $stmt = $pdo->prepare('SELECT SQL_CALC_FOUND_ROWS id, name, icon FROM categories WHERE name LIKE :q ORDER BY name LIMIT :limit OFFSET :offset');
            $stmt->bindValue(':q', '%' . $q . '%', PDO::PARAM_STR);
        } else {
            $stmt = $pdo->prepare('SELECT SQL_CALC_FOUND_ROWS id, name, icon FROM categories ORDER BY name LIMIT :limit OFFSET :offset');
        }
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->bindValue(':offset', $offset, PDO::PARAM_INT);
        $stmt->execute();
        $rows = $stmt->fetchAll();
        $total = (int)$pdo->query('SELECT FOUND_ROWS()')->fetchColumn();

        json_ok(['data' => $rows, 'page' => $page, 'limit' => $limit, 'total' => $total, 'query' => $q]);
    } catch (Throwable $e) {
        json_err('Failed to fetch categories', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- GET /recipes ----
// Supports: GET /recipes, GET /recipes?id=123, GET /recipes?category_id=1, GET /recipes?q=search
if ($method === 'GET' && preg_match('#^/recipes$#', $path)) {
    try {
        $id = isset($_GET['id']) ? (int)$_GET['id'] : null;
        $categoryId = isset($_GET['category_id']) ? (int)$_GET['category_id'] : null;
        $q = isset($_GET['q']) ? trim((string)$_GET['q']) : '';

        if ($id) {
            $stmt = $pdo->prepare('SELECT id, category_id, name, recipe_time, details, image, ingredients FROM recipes WHERE id = ?');
            $stmt->execute([$id]);
            $row = $stmt->fetch();
            if (!$row) json_err('Recipe not found', 404);
            json_ok(format_recipe_row($row));
        }

        // Handle search query
        if ($q !== '') {
            $page = max(1, (int)($_GET['page'] ?? 1));
            $limit = min(100, max(1, (int)($_GET['limit'] ?? 50)));
            $offset = ($page - 1) * $limit;

            // Search in recipe name, details, and ingredients
            $searchQuery = '%' . $q . '%';
            $stmt = $pdo->prepare('
                SELECT SQL_CALC_FOUND_ROWS id, category_id, name, recipe_time, details, image, ingredients
                FROM recipes 
                WHERE name LIKE :search 
                   OR details LIKE :search2
                   OR (ingredients IS NOT NULL AND JSON_SEARCH(ingredients, "one", :search3) IS NOT NULL)
                ORDER BY 
                    CASE WHEN name LIKE :search4 THEN 1 ELSE 2 END,
                    name
                LIMIT :limit OFFSET :offset
            ');
            $stmt->bindValue(':search', $searchQuery, PDO::PARAM_STR);
            $stmt->bindValue(':search2', $searchQuery, PDO::PARAM_STR);
            $stmt->bindValue(':search3', $searchQuery, PDO::PARAM_STR);
            $stmt->bindValue(':search4', $searchQuery, PDO::PARAM_STR);
            $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
            $stmt->bindValue(':offset', $offset, PDO::PARAM_INT);
            $stmt->execute();
            $rows = $stmt->fetchAll();
            $total = (int)$pdo->query('SELECT FOUND_ROWS()')->fetchColumn();

            // Format ingredients for all rows
            $rows = array_map('format_recipe_row', $rows);

            json_ok(['data' => $rows, 'page' => $page, 'limit' => $limit, 'total' => $total, 'query' => $q]);
        }

        if ($categoryId) {
            $page = max(1, (int)($_GET['page'] ?? 1));
            $limit = min(100, max(1, (int)($_GET['limit'] ?? 50)));
            $offset = ($page - 1) * $limit;

            $stmt = $pdo->prepare('
                SELECT SQL_CALC_FOUND_ROWS id, category_id, name, recipe_time, details, image, ingredients
                FROM recipes 
                WHERE category_id = :category_id 
                ORDER BY name 
                LIMIT :limit OFFSET :offset
            ');
            $stmt->bindValue(':category_id', $categoryId, PDO::PARAM_INT);
            $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
            $stmt->bindValue(':offset', $offset, PDO::PARAM_INT);
            $stmt->execute();
            $rows = $stmt->fetchAll();
            $total = (int)$pdo->query('SELECT FOUND_ROWS()')->fetchColumn();

            // Format ingredients for all rows
            $rows = array_map('format_recipe_row', $rows);

            json_ok(['data' => $rows, 'page' => $page, 'limit' => $limit, 'total' => $total]);
        }

        // list all with simple pagination (when no search or category filter)
        $page = max(1, (int)($_GET['page'] ?? 1));
        $limit = min(100, max(1, (int)($_GET['limit'] ?? 50)));
        $offset = ($page - 1) * $limit;

        $stmt = $pdo->prepare('SELECT SQL_CALC_FOUND_ROWS id, category_id, name, recipe_time, details, image, ingredients FROM recipes ORDER BY id DESC LIMIT :limit OFFSET :offset');
        $stmt->bindValue(':limit', $limit, PDO::PARAM_INT);
        $stmt->bindValue(':offset', $offset, PDO::PARAM_INT);
        $stmt->execute();
        $rows = $stmt->fetchAll();
        $total = (int)$pdo->query('SELECT FOUND_ROWS()')->fetchColumn();

        // Format ingredients for all rows
        $rows = array_map('format_recipe_row', $rows);

        json_ok(['data' => $rows, 'page' => $page, 'limit' => $limit, 'total' => $total]);
    } catch (Throwable $e) {
        json_err('Failed to fetch recipes', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- POST /recipes (create) ----
if ($method === 'POST' && preg_match('#^/recipes$#', $path)) {
    try {
        $ctype = $_SERVER['CONTENT_TYPE'] ?? '';
        if (stripos($ctype, 'application/json') === false) {
            json_err('Content-Type must be application/json', 415);
        }
        $body = read_json_body();
        $categoryId = (int)($body['category_id'] ?? 0);
        $name       = trim((string)($body['name'] ?? ''));
        $recipeTime = isset($body['recipe_time']) ? (int)$body['recipe_time'] : null; // minutes
        $details    = isset($body['details']) ? (string)$body['details'] : null;      // Markdown/HTML
        $image      = isset($body['image']) ? trim((string)$body['image']) : null;    // path or URL
        $ingredients = isset($body['ingredients']) ? parse_ingredients($body['ingredients']) : null; // JSON array

        if ($categoryId <= 0) json_err('`category_id` is required');
        if ($name === '' || mb_strlen($name) > 150) json_err('`name` is required (1-150 chars)');

        // ensure category exists
        $chk = $pdo->prepare('SELECT id FROM categories WHERE id = ?');
        $chk->execute([$categoryId]);
        if (!$chk->fetch()) json_err('Category not found', 404);

        $stmt = $pdo->prepare('INSERT INTO recipes (category_id, name, recipe_time, details, image, ingredients) VALUES (?,?,?,?,?,?)');
        $stmt->execute([$categoryId, $name, $recipeTime, $details, $image, $ingredients]);
        $id = (int)$pdo->lastInsertId();
        
        // Get the created recipe to return with properly formatted ingredients
        $getStmt = $pdo->prepare('SELECT id, category_id, name, recipe_time, details, image, ingredients FROM recipes WHERE id = ?');
        $getStmt->execute([$id]);
        $row = $getStmt->fetch();
        
        http_response_code(201);
        json_ok(format_recipe_row($row), 201);
    } catch (Throwable $e) {
        json_err('Failed to create recipe', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- PUT /recipes/{id} (update) ----
if ($method === 'PUT' && preg_match('#^/recipes/(\d+)$#', $path, $m)) {
    try {
        $id = (int)$m[1];
        $ctype = $_SERVER['CONTENT_TYPE'] ?? '';
        if (stripos($ctype, 'application/json') === false) {
            json_err('Content-Type must be application/json', 415);
        }
        $body = read_json_body();
        $sets = [];
        $params = [];

        if (isset($body['category_id'])) {
            $cid = (int)$body['category_id'];
            if ($cid <= 0) json_err('`category_id` must be a positive integer');
            // ensure category exists
            $chk = $pdo->prepare('SELECT id FROM categories WHERE id = ?');
            $chk->execute([$cid]);
            if (!$chk->fetch()) json_err('Category not found', 404);
            $sets[] = 'category_id = ?';
            $params[] = $cid;
        }
        if (isset($body['name'])) {
            $name = trim((string)$body['name']);
            if ($name === '' || mb_strlen($name) > 150) json_err('`name` must be 1-150 chars');
            $sets[] = 'name = ?';
            $params[] = $name;
        }
        if (array_key_exists('recipe_time', $body)) {
            $rt = $body['recipe_time'] === null ? null : (int)$body['recipe_time'];
            $sets[] = 'recipe_time = ?';
            $params[] = $rt;
        }
        if (array_key_exists('details', $body)) {
            $sets[] = 'details = ?';
            $params[] = (string)$body['details'];
        }
        if (array_key_exists('image', $body)) {
            $sets[] = 'image = ?';
            $img = $body['image'];
            $params[] = $img === null ? null : trim((string)$img);
        }
        if (array_key_exists('ingredients', $body)) {
            $sets[] = 'ingredients = ?';
            $params[] = parse_ingredients($body['ingredients']);
        }

        if (!$sets) json_err('Nothing to update');

        $params[] = $id;
        $sql = 'UPDATE recipes SET ' . implode(', ', $sets) . ' WHERE id = ?';
        $stmt = $pdo->prepare($sql);
        $stmt->execute($params);
        if ($stmt->rowCount() === 0) {
            // Could be not found or same values; check existence explicitly
            $chk = $pdo->prepare('SELECT id FROM recipes WHERE id = ?');
            $chk->execute([$id]);
            if (!$chk->fetch()) json_err('Recipe not found', 404);
        }
        // return the updated row
        $get = $pdo->prepare('SELECT id, category_id, name, recipe_time, details, image, ingredients FROM recipes WHERE id = ?');
        $get->execute([$id]);
        json_ok(format_recipe_row($get->fetch()));
    } catch (Throwable $e) {
        json_err('Failed to update recipe', 500, ['detail' => $e->getMessage()]);
    }
}

// ---- DELETE /recipes/{id} (delete) ----
if ($method === 'DELETE' && preg_match('#^/recipes/(\d+)$#', $path, $m)) {
    try {
        $id = (int)$m[1];
        $stmt = $pdo->prepare('DELETE FROM recipes WHERE id = ?');
        $stmt->execute([$id]);
        if ($stmt->rowCount() === 0) json_err('Recipe not found', 404);
        json_ok(['deleted' => $id]);
    } catch (Throwable $e) {
        json_err('Failed to delete recipe', 500, ['detail' => $e->getMessage()]);
    }
}

// 404 fallback
json_err('Not found', 404, ['path' => $path, 'method' => $method]);