"""Admin database browser: schema/table listing, row browsing, and the two
destructive truncate endpoints."""

import asyncio

from fastapi import APIRouter, HTTPException, Request

from ..auth_deps import _require_admin_auth
from ..schemas import TruncateSchemaRequest, TruncateTableRequest
from ..security import _bounded_query_limit, _safe_error_detail
from ..services import action_logger, db, settings

router = APIRouter()


@router.get("/api/databases")
async def databases(request: Request, include_tables: bool = False):
    _require_admin_auth(request)
    try:
        schemas = await db.list_schemas()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=_safe_error_detail("Database unavailable", exc))
    if not include_tables:
        return {"schemas": schemas}

    tables_results = await asyncio.gather(*[db.list_tables(schema) for schema in schemas], return_exceptions=True)
    output = [
        {"schema": schema, "tables": tables if not isinstance(tables, BaseException) else []}
        for schema, tables in zip(schemas, tables_results)
    ]
    return {"schemas": output}


@router.get("/api/databases/{schema}/tables")
async def tables(request: Request, schema: str):
    _require_admin_auth(request)
    try:
        return {"schema": schema, "tables": await db.list_tables(schema)}
    except Exception as exc:
        raise HTTPException(status_code=503, detail=_safe_error_detail("Database unavailable", exc))


@router.post("/api/database/truncate-table")
async def truncate_table(request: Request, payload: TruncateTableRequest):
    _require_admin_auth(request)
    expected_confirmation = f"TRUNCATE {payload.schema_name}.{payload.table_name}"
    if payload.confirm_text.strip() != expected_confirmation:
        raise HTTPException(
            status_code=400,
            detail=f"Confirmation mismatch. Expected exact text: {expected_confirmation}",
        )
    expected_owner_confirmation = settings.destructive_confirmation_phrase.strip()
    if expected_owner_confirmation and payload.owner_confirm_text.strip() != expected_owner_confirmation:
        raise HTTPException(
            status_code=400,
            detail=f"Owner confirmation mismatch. Expected exact text: {expected_owner_confirmation}",
        )
    try:
        await db.truncate_table(payload.schema_name, payload.table_name)
    except Exception as exc:
        raise HTTPException(status_code=503, detail=_safe_error_detail("Database unavailable", exc))
    action_logger.warning("truncate_table schema=%s table=%s", payload.schema_name, payload.table_name)
    return {"ok": True, "message": f"Truncated {payload.schema_name}.{payload.table_name}"}


@router.post("/api/database/truncate-schema")
async def truncate_schema(request: Request, payload: TruncateSchemaRequest):
    _require_admin_auth(request)
    expected_confirmation = f"TRUNCATE ALL {payload.schema_name}"
    if payload.confirm_text.strip() != expected_confirmation:
        raise HTTPException(
            status_code=400,
            detail=f"Confirmation mismatch. Expected exact text: {expected_confirmation}",
        )
    expected_owner_confirmation = settings.destructive_confirmation_phrase.strip()
    if expected_owner_confirmation and payload.owner_confirm_text.strip() != expected_owner_confirmation:
        raise HTTPException(
            status_code=400,
            detail=f"Owner confirmation mismatch. Expected exact text: {expected_owner_confirmation}",
        )
    try:
        result = await db.truncate_schema(payload.schema_name)
    except Exception as exc:
        raise HTTPException(status_code=503, detail=_safe_error_detail("Database unavailable", exc))
    action_logger.warning("truncate_schema schema=%s tables=%s", payload.schema_name, result["truncated_tables"])
    return {"ok": True, **result}


@router.get("/api/database/data")
async def get_table_data(
    request: Request,
    schema_name: str,
    table_name: str,
    limit: int = 100
):
    _require_admin_auth(request)
    limit = _bounded_query_limit(limit, default=100)
    try:
        data = await db.get_table_data(schema_name, table_name, limit)
        return {"ok": True, "data": data, "rows": data.get("rows", []), "count": data.get("count", 0)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        action_logger.error("Failed to fetch table data schema=%s table=%s: %s", schema_name, table_name, exc)
        raise HTTPException(status_code=503, detail=_safe_error_detail("Database unavailable", exc))
