# Auctions API - Zig Implementation

This is a Zig implementation of an auctions engine API, converted from the [Haskell version](https://github.com/wallymathieu/auctions-api-haskell).

## Features

- REST API for managing auctions and bids
- Event sourcing with JSON file persistence
- JWT-based authentication (via decoded JWT header)
- Timed ascending (English) auction support
- Thread-safe in-memory state management

## Requirements

- Zig 0.13.0 or later

## Building

```bash
zig build
```

## Running

```bash
zig build run
```

The server will start on `http://0.0.0.0:8080` by default.

## Configuration

The application can be configured using environment variables:

- `PORT` - Server port (default: `8080`)
- `EVENTS_FILE` - Path to events file (default: `tmp/events.jsonl`)

Example:

```bash
PORT=3000 EVENTS_FILE=/data/events.jsonl zig build run
```

## Testing

```bash
zig build test
```

## API Endpoints

### Authentication

All write operations require authentication via the `x-jwt-payload` header. The header should contain a Base64-encoded JSON payload (not an actual JWT).

Example JWT payload for a buyer/seller:
```json
{
  "sub": "a1",
  "name": "Test User",
  "u_typ": "0"
}
```

Example JWT payload for support:
```json
{
  "sub": "s1",
  "u_typ": "1"
}
```

### Endpoints

- `GET /auctions` - List all auctions
- `GET /auctions/:id` - Get auction details, including bids and winner information
- `POST /auctions` - Create a new auction
- `POST /auctions/:id/bids` - Place a bid on an auction

### Example Requests

#### Create an auction

```bash
curl -X POST http://localhost:8080/auctions \
  -H "Content-Type: application/json" \
  -H "x-jwt-payload: eyJzdWIiOiJhMSIsICJuYW1lIjoiVGVzdCIsICJ1X3R5cCI6IjAifQo=" \
  -d '{
    "id": 1,
    "startsAt": 1672574400,
    "endsAt": 1704110400,
    "title": "Test Auction",
    "currency": "VAC"
  }'
```

Note: Timestamps are Unix timestamps (seconds since epoch).

#### Place a bid

```bash
curl -X POST http://localhost:8080/auctions/1/bids \
  -H "Content-Type: application/json" \
  -H "x-jwt-payload: eyJzdWIiOiJhMiIsICJuYW1lIjoiQnV5ZXIiLCAidV90eXAiOiIwIn0K=" \
  -d '{
    "amount": 100
  }'
```

#### Get all auctions

```bash
curl http://localhost:8080/auctions
```

#### Get a specific auction

```bash
curl http://localhost:8080/auctions/1
```

## Architecture

The project is organized into modules:

- `models.zig` - Core domain models (User, Auction, Bid, Events, etc.)
- `domain.zig` - Business logic and auction state management
- `jwt.zig` - JWT authentication (Base64 decoding and user parsing)
- `persistence.zig` - Event sourcing and JSON file I/O
- `api.zig` - HTTP request handling and routing
- `main.zig` - HTTP server setup and connection handling

## Event Sourcing

The application uses event sourcing to persist all changes. Events are stored in `tmp/events.jsonl` as newline-delimited JSON. On startup, the application replays all events to rebuild the current state.

## License

MIT
