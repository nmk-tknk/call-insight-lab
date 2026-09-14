"""Pydantic schema for per-call structured extraction (schema v0.2, vocab v0.1)."""
from __future__ import annotations
from typing import Literal
from pydantic import BaseModel, Field

ReasonL1 = Literal["BILLING", "CONTRACT", "TECHNICAL", "PROCEDURE", "COMPLAINT", "INFO", "OTHER"]
ReasonL2 = Literal[
    "BILL_AMOUNT_INQUIRY", "DOUBLE_CHARGE", "PAYMENT_METHOD_CHANGE", "PAYMENT_DUE_INQUIRY",
    "CANCEL_REQUEST", "PLAN_CHANGE", "CONTRACT_DETAILS_INQUIRY",
    "APP_LOGIN_TROUBLE", "SERVICE_OUTAGE",
    "ADDRESS_CHANGE", "NAME_CHANGE", "DOCUMENT_REISSUE",
    "AGENT_CONDUCT", "GENERAL_COMPLAINT",
    "SERVICE_INFO_GENERAL", "OTHER",
]
RequestType = Literal["inquiry", "procedure", "complaint", "cancel_intent", "feedback", "other"]
Trigger = Literal[
    "received_notice", "viewed_bill", "app_or_web_change", "media_sns", "word_of_mouth",
    "followup_of_previous_contact", "our_outbound_contact", "life_event", "unknown", "other",
]
Product = Literal["PLAN_A", "PLAN_B", "OPTION_SECURITY", "APP", "UNKNOWN"]
Touchpoint = Literal[
    "DOC_BILL_STATEMENT", "DOC_RATE_CHANGE_NOTICE_2609", "DOC_CONTRACT_CONFIRM",
    "APP_LOGIN", "APP_CANCEL_FLOW", "WEB_MYPAGE", "TERM_PRORATION", "TERM_BILLING_CYCLE",
    "NONE", "OTHER",
]
ConfusionType = Literal["direct", "indirect_misread", "indirect_clarify", "none"]
Resolution = Literal["resolved", "escalated", "callback_promised", "unresolved", "unknown"]
Emotion = Literal["negative", "neutral", "positive"]


class CallExtraction(BaseModel):
    # --- non-analysis: summary (vocabulary induction / drill-down only) ---
    request_summary: str = Field(description="顧客が求めたことを1文で")

    # --- analysis columns (closed vocabularies) ---
    reason_l1: ReasonL1
    reason_l2: ReasonL2
    reason_other_text: str = ""
    reason_secondary: list[ReasonL2] = Field(default_factory=list)
    request_type: RequestType
    trigger_code: Trigger
    trigger_other_text: str = ""
    product_code: Product
    touchpoint_code: Touchpoint
    touchpoint_other_text: str = ""

    confusion_reasoning: str = ""
    confusion_signal: bool
    confusion_type: ConfusionType
    confusion_touchpoint_code: Touchpoint
    confusion_evidence: str = ""

    resolution_reasoning: str = ""
    resolution_status: Resolution
    resolution_evidence: str = ""

    repeat_reasoning: str = ""
    repeat_contact_signal: bool
    repeat_evidence: str = ""

    emotion_end: Emotion
