# tau-bench Airline triage

Official tau-bench reward is the scoring source of truth. This file only buckets failures for nullalis iteration planning.

## Summary

- tasks: 50
- pass_rate: 0.100
- mean_tool_calls: 2.46
- mean_latency_ms: 106140
- p50_ttft_ms: 9083
- p95_ttft_ms: 105294

## 12-category breakdown

| Category | Failures |
|---|---:|
| agentic_execution | 10 |
| error_recovery_depth | 31 |
| memory_recall | 0 |
| multi_turn_coherence | 0 |
| persona_fidelity | 1 |
| proactive_research | 2 |
| professional_synthesis | 0 |
| safety_refusal | 0 |
| self_awareness | 0 |
| subagent_dispatch | 0 |
| tool_chaining | 0 |
| tool_discipline | 1 |

## Failed tasks

### agentic_execution

- task 0: steps=12 tool_calls=5 parse_errors=0 stopped=done expected=[book_reservation] actual=[get_user_details,search_direct_flight,search_direct_flight,search_direct_flight,search_onestop_flight] error=none
- task 1: steps=7 tool_calls=4 parse_errors=0 stopped=done expected=[cancel_reservation] actual=[get_user_details,get_reservation_details,get_reservation_details,get_reservation_details] error=none
- task 3: steps=16 tool_calls=10 parse_errors=0 stopped=done expected=[update_reservation_flights,update_reservation_baggages] actual=[get_user_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,search_direct_flight,search_onestop_flight] error=none
- task 6: steps=8 tool_calls=4 parse_errors=0 stopped=done expected=[update_reservation_flights] actual=[get_user_details,get_reservation_details,search_direct_flight,search_onestop_flight] error=none
- task 7: steps=10 tool_calls=6 parse_errors=0 stopped=done expected=[update_reservation_flights] actual=[get_user_details,get_reservation_details,search_direct_flight,search_onestop_flight,think,search_onestop_flight] error=none
- task 8: steps=11 tool_calls=5 parse_errors=0 stopped=done expected=[cancel_reservation,book_reservation] actual=[get_user_details,get_reservation_details,search_direct_flight,search_direct_flight,search_onestop_flight] error=none
- task 9: steps=15 tool_calls=6 parse_errors=0 stopped=done expected=[cancel_reservation,book_reservation,book_reservation,book_reservation] actual=[get_user_details,get_reservation_details,search_direct_flight,search_direct_flight,search_direct_flight,search_direct_flight] error=none
- task 10: steps=4 tool_calls=4 parse_errors=0 stopped=done expected=[cancel_reservation,book_reservation] actual=[get_user_details,get_reservation_details,get_reservation_details,transfer_to_human_agents] error=none
- task 11: steps=10 tool_calls=5 parse_errors=0 stopped=done expected=[book_reservation] actual=[get_user_details,get_reservation_details,search_direct_flight,search_direct_flight,calculate] error=none
- task 17: steps=22 tool_calls=13 parse_errors=0 stopped=done expected=[none] actual=[get_user_details,get_reservation_details,search_direct_flight,search_onestop_flight,search_direct_flight,search_direct_flight,calculate,search_onestop_flight,calculate,calculate,calculate,calculate,update_reservation_flights] error=none

### error_recovery_depth

- task 19: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 20: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 21: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 22: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 23: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 24: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 25: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 26: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 27: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 28: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 29: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 30: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 31: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 32: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 33: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 34: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 35: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 36: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 37: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 38: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 39: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 40: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 41: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 42: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 43: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 44: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 45: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 46: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 47: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 48: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError
- task 49: steps=0 tool_calls=0 parse_errors=0 stopped= expected=[none] actual=[none] error=RateLimitError

### persona_fidelity

- task 4: steps=11 tool_calls=7 parse_errors=0 stopped=done expected=[update_reservation_flights,update_reservation_passengers,update_reservation_baggages] actual=[get_user_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,search_direct_flight,search_onestop_flight] error=none

### proactive_research

- task 14: steps=12 tool_calls=8 parse_errors=0 stopped=done expected=[get_reservation_details,search_direct_flight,search_direct_flight,calculate,update_reservation_baggages] actual=[get_user_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,search_onestop_flight] error=none
- task 16: steps=14 tool_calls=11 parse_errors=0 stopped=done expected=[get_user_details,send_certificate] actual=[get_user_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,transfer_to_human_agents] error=none

### tool_discipline

- task 5: steps=14 tool_calls=10 parse_errors=1 stopped=done expected=[update_reservation_flights,update_reservation_passengers,update_reservation_baggages] actual=[get_user_details,get_reservation_details,get_reservation_details,get_reservation_details,get_reservation_details,search_direct_flight,search_onestop_flight,update_reservation_baggages,update_reservation_passengers,update_reservation_flights] error=none
