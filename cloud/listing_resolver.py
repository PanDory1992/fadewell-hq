"""Conservative matching between a newly seen Vinted listing and an unlisted DEN item."""
from __future__ import annotations

import re
from typing import Any

STOP_WORDS = {"jeans", "denim", "vintage", "pants", "trousers", "fit", "blue", "black", "with", "for", "the", "and", "new", "size"}
MARKER = re.compile(r"#den[-_ ]?0*(\d{1,5})\b", re.I)
SIZE = re.compile(r"\b([wl])\s*([0-9]{2})\b", re.I)
SLASH_SIZE = re.compile(r"\b([0-9]{2})\s*/\s*([0-9]{2})\b")
MODEL = re.compile(r"\b([0-9]{3,4})\b")


def text(value: Any) -> str:
    return str(value or "").lower().replace("’", "").replace("'", "")


def tokens(value: Any) -> set[str]:
    return {token for token in re.findall(r"[a-z0-9]+", text(value)) if len(token) >= 3 and token not in STOP_WORDS}


def sizes(value: Any) -> set[str]:
    explicit = {f"{kind.lower()}{number}" for kind, number in SIZE.findall(text(value))}
    slash_pairs = {f"{kind}{number}" for waist, length in SLASH_SIZE.findall(text(value)) for kind, number in (("w", waist), ("l", length))}
    return explicit | slash_pairs


def colours(value: Any) -> set[str]:
    source = text(value)
    families = {
        "blue": r"\b(?:blue|midblue|mid blue|indigo|navy|stonewash)\b",
        "black": r"\b(?:black|charcoal)\b",
        "grey": r"\b(?:grey|gray)\b",
        "white": r"\b(?:white|ecru|cream|beige)\b",
        "green": r"\b(?:green|olive|smaragd)\b",
    }
    return {family for family, pattern in families.items() if re.search(pattern, source)}


def countries(value: Any) -> set[str]:
    source = text(value)
    aliases = {
        "poland": r"\b(?:poland|polska|pl)\b",
        "usa": r"\b(?:usa|u s a|america)\b",
        "uk": r"\b(?:uk|england|britain)\b",
        "spain": r"\b(?:spain|espana)\b",
    }
    return {country for country, pattern in aliases.items() if re.search(pattern, source)}


def models(value: Any) -> set[str]:
    return set(MODEL.findall(text(value)))


def marker(value: Any) -> str | None:
    found = MARKER.search(text(value))
    return f"DEN-{int(found.group(1)):03d}" if found else None


def score(listing: dict[str, Any], item: dict[str, Any]) -> dict[str, Any]:
    listing_text = f"{listing.get('title', '')} {listing.get('description', '')}"
    item_text = f"{item.get('name', '')} {item.get('category', '')} {item.get('advantage', '')}"
    direct = marker(listing_text)
    if direct and direct == item.get("item_id"):
        return {"item": item, "score": 1000, "reasons": ["marker #den"]}

    listing_tokens, item_tokens = tokens(listing_text), tokens(item_text)
    shared = listing_tokens & item_tokens
    listing_sizes, item_sizes = sizes(listing_text), sizes(item_text)
    listing_models, item_models = models(listing_text), models(item_text)
    listing_colours, item_colours = colours(listing_text), colours(item_text)
    listing_countries, item_countries = countries(listing_text), countries(item_text)
    reasons: list[str] = []
    points = 0
    if shared:
        points += min(38, 8 * len(shared))
        reasons.append("wspólne słowa: " + ", ".join(sorted(shared)[:4]))
    if listing_sizes & item_sizes:
        points += 22 * len(listing_sizes & item_sizes)
        reasons.append("zgodny rozmiar " + ", ".join(sorted(listing_sizes & item_sizes)))
    if listing_models & item_models:
        points += 30
        reasons.append("zgodny model " + ", ".join(sorted(listing_models & item_models)))
    if listing_colours and item_colours:
        if listing_colours & item_colours:
            points += 12
            reasons.append("zgodny kolor " + ", ".join(sorted(listing_colours & item_colours)))
        else:
            points -= 20
            reasons.append("sprzeczny kolor")
    if listing_countries and item_countries:
        if listing_countries & item_countries:
            points += 10
            reasons.append("zgodny kraj pochodzenia")
        else:
            points -= 20
            reasons.append("sprzeczny kraj pochodzenia")
    estimate = item.get("estimate_sale_price")
    price = listing.get("price_pln")
    try:
        if estimate and price and abs(float(price) - float(estimate)) / float(estimate) <= 0.30:
            points += 5
            reasons.append("cena blisko estymaty")
    except (TypeError, ValueError, ZeroDivisionError):
        pass
    return {"item": item, "score": points, "reasons": reasons, "strong": bool(listing_sizes & item_sizes) and bool(listing_models & item_models)}


def best_match(listing: dict[str, Any], items: list[dict[str, Any]]) -> dict[str, Any] | None:
    matches = sorted((score(listing, item) for item in items), key=lambda match: match["score"], reverse=True)
    if not matches or matches[0]["score"] <= 0:
        return None
    best, runner_up = matches[0], matches[1] if len(matches) > 1 else None
    exact_marker = best["score"] == 1000
    high_confidence = exact_marker or (best["score"] >= 80 and best.get("strong") and (not runner_up or best["score"] - runner_up["score"] >= 25))
    best["auto"] = high_confidence
    best["confidence"] = "HIGH" if high_confidence else "MEDIUM" if best["score"] >= 35 else "LOW"
    return best
