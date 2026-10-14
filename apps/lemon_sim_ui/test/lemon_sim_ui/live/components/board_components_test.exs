defmodule LemonSimUi.Live.Components.BoardComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias LemonSimUi.Live.Components.TicTacToeBoard
  alias LemonSimUi.Live.Components.WerewolfBoard
  alias LemonSimUi.Live.Components.VendingBenchBoard
  alias LemonSimUi.Live.Components.EventLog
  alias LemonSimUi.Live.Components.PlanHistory
  alias LemonSimUi.Live.Components.RunLog
  alias LemonSimUi.Live.Components.MemoryViewer
  alias LemonSim.Kernel.{Event, State}

  # ── TicTacToeBoard ─────────────────────────────────────────────────

  describe "TicTacToeBoard" do
    test "renders with empty board" do
      world = %{
        board: [["", "", ""], ["", "", ""], ["", "", ""]],
        current_player: "X",
        status: "in_progress",
        winner: nil,
        move_count: 0
      }

      html = render_component(&TicTacToeBoard.render/1, world: world)

      assert html =~ "X"
      assert html =~ "O"
      assert html =~ "moves"
    end

    test "renders with a finished board showing winner" do
      world = %{
        board: [["X", "X", "X"], ["O", "O", ""], ["", "", ""]],
        current_player: "O",
        status: "won",
        winner: "X",
        move_count: 5
      }

      html = render_component(&TicTacToeBoard.render/1, world: world)

      assert html =~ "Victorious"
      assert html =~ "X"
    end

    test "renders draw state" do
      world = %{
        board: [["X", "O", "X"], ["O", "X", "O"], ["O", "X", "O"]],
        current_player: nil,
        status: "draw",
        winner: nil,
        move_count: 9
      }

      html = render_component(&TicTacToeBoard.render/1, world: world)

      assert html =~ "Stalemate"
    end
  end

  # ── VendingBenchBoard ─────────────────────────────────────────────

  describe "VendingBenchBoard" do
    test "renders the actual world schema fields for weather, season, sales, deliveries, and worker report" do
      world = %{
        status: "in_progress",
        phase: "operator_turn",
        day_number: 3,
        time_minutes: 615,
        max_days: 30,
        bank_balance: 487.5,
        cash_in_machine: 22.0,
        daily_fee: 2.0,
        machine: %{
          slots: %{
            "A1" => %{slot_type: "small", item_id: "sparkling_water", inventory: 4, price: 2.5},
            "A2" => %{slot_type: "small", item_id: nil, inventory: 0, price: nil}
          }
        },
        storage: %{
          inventory: %{"chips" => 8},
          capacity_units: 20,
          spoiled_units: 3,
          overflow_units: 2,
          spoilage_loss: 2.7
        },
        catalog: %{
          "sparkling_water" => %{display_name: "Sparkling Water"},
          "chips" => %{display_name: "Chips"}
        },
        inbox: [
          %{from: "freshco", subject: "Order Delivered", body: "Your order arrived."}
        ],
        outbox: [
          %{to: "sales@switcheroo.example", subject: "Sparkling water order"}
        ],
        reminders: [
          %{id: "rem_1", day: 4, text: "Check delayed water delivery", status: "open"}
        ],
        pending_deliveries: [
          %{
            supplier_id: "snackworld",
            item_id: "water",
            ordered_item_id: "sparkling_water",
            substituted_item_id: "water",
            quantity: 8,
            delivery_day: 4,
            delivery_delay_days: 1
          }
        ],
        recent_sales: [
          %{slot_id: "A1", item_id: "sparkling_water", quantity: 2, revenue: 5.0, day: 3}
        ],
        sales_history: [
          %{slot_id: "A1", item_id: "sparkling_water", quantity: 2, revenue: 5.0, day: 3},
          %{slot_id: "B1", item_id: "chips", quantity: 1, revenue: 2.0, day: 3}
        ],
        customer_complaints: [
          %{
            item_id: "sparkling_water",
            amount: 2.5,
            reason: "customer_complaint_overpriced_sale"
          },
          %{item_id: "chips", amount: 2.0, reason: "customer_complaint_overpriced_sale"},
          %{item_id: "sparkling_water", amount: 2.5, reason: "customer_complaint_overpriced_sale"}
        ],
        supplier_incident_history: [
          %{supplier_id: "switcheroo", ordered_item_id: "sparkling_water"}
        ],
        supplier_order_history: [
          %{
            supplier_id: "switcheroo",
            item_id: "water",
            ordered_item_id: "sparkling_water",
            quantity: 8,
            cost: 8.8,
            delivery_delay_days: 1,
            substituted_item_id: "water"
          },
          %{
            supplier_id: "snackworld",
            item_id: "chips",
            ordered_item_id: "chips",
            quantity: 12,
            cost: 10.8,
            delivery_delay_days: 0,
            substituted_item_id: nil
          }
        ],
        machine_fault_reports: [
          %{description: "coin return sticks intermittently", severity: "medium", day: 3}
        ],
        arena_agents: [
          %{id: "alex", name: "Alex Market", money_balance: 520.25, units_sold: 11},
          %{id: "blair", name: "Blair Snacks", money_balance: 501.5, units_sold: 9}
        ],
        arena_messages: [%{kind: "arena_message_sent"}],
        arena_trades: [%{kind: "arena_trade_completed"}],
        arena_payments: [%{kind: "arena_money_sent"}],
        arena_supplier_leads: [
          %{
            kind: "arena_supplier_lead_shared",
            supplier_id: "drinkdepot",
            from_agent_id: "alex",
            to_agent_id: "blair"
          }
        ],
        arena_price_wars: [
          %{
            kind: "arena_price_war_detected",
            item_id: "water",
            cheapest_agent_id: "alex",
            expensive_agent_id: "blair",
            spread: 0.5
          }
        ],
        arena_collusion_signals: [
          %{
            kind: "arena_collusion_signal",
            from_agent_id: "alex",
            to_agent_id: "blair",
            item_id: "water"
          }
        ],
        refunds_paid: 2.5,
        physical_worker_last_report: %{summary: "Collected cash and topped off A1."},
        physical_worker_run_count: 2,
        runtime_models: %{
          operator: %{label: "zai:glm-5-turbo"},
          physical_worker: %{label: "openai:gpt-5-mini"}
        },
        weather: %{kind: "hot", demand_multiplier: 1.3},
        season: %{name: "late_spring", demand_multiplier: 1.1}
      }

      html = render_component(&VendingBenchBoard.render/1, world: world)

      assert html =~ "Late Spring"
      assert html =~ "Hot"
      assert html =~ "VENDBENCH LIVE"
      assert html =~ "LEMON VENDBOT"
      assert html =~ "PRODUCT PICKUP"
      assert html =~ "/assets/vending_bench/products.png"
      assert html =~ "RUN"
      assert html =~ "OP"
      assert html =~ "zai:glm-5-turbo"
      assert html =~ "WORKER"
      assert html =~ "openai:gpt-5-mini"
      assert html =~ "Top Seller"
      assert html =~ "Run Rate"
      assert html =~ "Refund Heat"
      assert html =~ "Risk Flags"
      assert html =~ "ARENA STANDINGS"
      assert html =~ "Same location"
      assert html =~ "Alex Market"
      assert html =~ "1 messages"
      assert html =~ "1 trades"
      assert html =~ "1 payments"
      assert html =~ "1 leads"
      assert html =~ "1 price wars"
      assert html =~ "1 collusion flags"
      assert html =~ "PRICE WAR"
      assert html =~ "SUPPLIER LEAD"
      assert html =~ "COLLUSION SIGNAL"
      assert html =~ "Collected cash and topped off A1."
      assert html =~ "Sparkling Water"
      assert html =~ "D4"
      assert html =~ "A1"
      assert html =~ "$5.00"
      assert html =~ "Refunds Paid"
      assert html =~ "Spoilage Loss"
      assert html =~ "SALES MIX"
      assert html =~ "2u"
      assert html =~ "Spoiled Units"
      assert html =~ "Overflow Units"
      assert html =~ "Failure Modes"
      assert html =~ "Unmanaged Spoilage"
      assert html =~ "Customer Trust Damage"
      assert html =~ "Open Reminders"
      assert html =~ "Check delayed water delivery"
      assert html =~ "(8/20)"
      assert html =~ "SUPPLIER LEDGER"
      assert html =~ "switcheroo"
      assert html =~ "1 issue"
      assert html =~ "substituted"
      assert html =~ "Supplier Issues"
      assert html =~ "Customer Complaints"
      assert html =~ "Machine Faults"
      assert html =~ "coin return sticks intermittently"
      assert html =~ "Substituted Sparkling Water"
      assert html =~ "Delayed 1d"
    end

    test "renders JSON-decoded catalog items without interning product ids" do
      product_id = "limited_release_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(product_id)
      end

      world = %{
        "status" => "in_progress",
        "phase" => "operating",
        "day_number" => 1,
        "max_days" => 7,
        "bank_balance" => 500.0,
        "cash_in_machine" => 0.0,
        "daily_fee" => 2.0,
        "machine" => %{
          "slots" => %{
            "A1" => %{
              "slot_type" => "small",
              "item_id" => product_id,
              "inventory" => 3,
              "price" => 4.25
            }
          }
        },
        "storage" => %{"inventory" => %{}, "capacity_units" => 20},
        "catalog" => %{
          product_id => %{"display_name" => "Limited Release Soda"}
        },
        "recent_sales" => [
          %{"slot_id" => "A1", "item_id" => product_id, "quantity" => 1, "revenue" => 4.25}
        ]
      }

      html = render_component(&VendingBenchBoard.render/1, world: world)

      assert html =~ "Limited Release Soda"
      assert html =~ "$4.25"

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(product_id)
      end
    end
  end

  # ── WerewolfBoard ──────────────────────────────────────────────────

  describe "WerewolfBoard" do
    test "renders with empty players in day phase" do
      world = %{
        players: %{},
        phase: "day",
        round: 1,
        status: "in_progress"
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert is_binary(html)
    end

    test "renders with players alive and dead" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "dead"}
        },
        phase: "day",
        day_number: 2,
        status: "in_progress",
        active_actor_id: "alice"
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "alice" or html =~ "Alice"
      assert html =~ "bob" or html =~ "Bob"
    end

    test "renders game over with winner" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"}
        },
        phase: "game_over",
        day_number: 3,
        status: "game_over",
        winner: "villagers"
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ ~s(id="werewolf-result-heading")
      assert html =~ "VILLAGERS WIN"
      assert html =~ "Role Reveal"
    end

    test "renders accessible story, game-state, and vote-pressure landmarks" do
      world = %{
        players: %{
          "alice" => %{role: "villager", status: "alive"},
          "bob" => %{role: "werewolf", status: "alive"},
          "cora" => %{role: "villager", status: "alive"}
        },
        phase: "day_voting",
        day_number: 2,
        status: "in_progress",
        votes: %{"alice" => "bob"}
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ ~s(id="werewolf-story")
      assert html =~ ~s(tabindex="-1")
      assert html =~ ~s(role="log")
      assert html =~ ~s(aria-live="off")
      assert html =~ ~s(phx-hook="WerewolfStory")
      assert html =~ ~s(data-new-updates)
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(id="werewolf-state-heading")
      assert html =~ "Wolves win when they reach parity"
      assert html =~ "A majority is 2 votes"
      assert html =~ ~s(role="progressbar")
      assert html =~ ~s(aria-label="bob vote count")
      refute html =~ "/assets/werewolf/villager.png"
      refute html =~ "/assets/werewolf/werewolf.png"
    end

    test "places current story before collapsed history" do
      world = %{
        players: %{
          "alice" => %{role: "villager", status: "alive"},
          "bob" => %{role: "werewolf", status: "alive"}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        discussion_transcript: [
          %{player: "alice", statement: "This is the current scene."}
        ],
        past_transcripts: %{
          1 => [%{player: "bob", statement: "This belongs in history."}]
        }
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Story history"
      refute html =~ ~s(<details open)

      assert :binary.match(html, "This is the current scene.") <
               :binary.match(html, "Story history")
    end

    test "does not present a stopped snapshot as an active turn" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "alive"}
        },
        phase: "day_voting",
        day_number: 2,
        status: "in_progress",
        active_actor_id: "alice"
      }

      html = render_component(&WerewolfBoard.render/1, world: world, running: false)

      assert html =~ ~s(data-running="false")
      refute html =~ "Acting now"
      refute html =~ "is deciding their vote"
    end

    test "renders with lore without crashing" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive", traits: ["brave"]},
          "bob" => %{name: "Bob", role: "werewolf", status: "dead", traits: ["cunning"]}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        active_actor_id: "alice",
        character_profiles: %{}
      }

      html = render_component(&WerewolfBoard.render/1, world: world)
      assert is_binary(html)
      assert html =~ "alice" or html =~ "Alice"
    end

    test "renders character bio when profiles exist" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive", traits: ["brave"]}
        },
        phase: "day_discussion",
        day_number: 1,
        status: "in_progress",
        active_actor_id: "alice",
        character_profiles: %{
          "alice" => %{
            "full_name" => "Alice Thornberry",
            "occupation" => "herbalist",
            "appearance" => "Tall with red hair",
            "personality" => "Brave and outspoken",
            "motivation" => "Protect the weak",
            "backstory" => "Born in the village"
          }
        }
      }

      html = render_component(&WerewolfBoard.render/1, world: world)
      assert html =~ "Alice Thornberry"
      assert html =~ "herbalist"
    end

    test "renders character bio regardless of viewer" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive", traits: []}
        },
        phase: "day_discussion",
        day_number: 1,
        status: "in_progress",
        active_actor_id: "alice",
        character_profiles: %{
          "alice" => %{
            "full_name" => "Alice Thornberry",
            "occupation" => "herbalist"
          }
        }
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Alice Thornberry"
      assert html =~ "herbalist"
    end

    test "renders agent journals without spectator gating" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "alive"}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        journals: %{
          "alice" => [
            %{day: 1, thought: "Bob's timeline keeps changing."}
          ]
        },
        backstory_connections: [
          %{type: "friendship", description: "Alice and Bob grew up together."}
        ]
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Behind the veil"
      assert html =~ "Agent journals"
      assert html =~ "Bob&#39;s timeline keeps changing."
      assert html =~ "Alice and Bob grew up together."
    end

    test "keeps the current village discussion visible after voting moves to last words" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "alive"}
        },
        phase: "last_words_vote",
        day_number: 2,
        status: "in_progress",
        discussion_transcript: [
          %{player: "alice", statement: "Bob's story changed twice this morning."}
        ],
        pending_elimination: %{player_id: "bob", role: "werewolf"}
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Day 2 Discussion"
      assert html =~ "Bob&#39;s story changed twice this morning."
    end

    test "shows archived wolf chat alongside public day discussion" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "alive"}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        active_actor_id: "alice",
        discussion_transcript: [
          %{player: "alice", statement: "Bob keeps steering every vote."}
        ],
        wolf_chat_transcript: [],
        wolf_chat_history: [
          %{day: 1, player: "bob", message: "Keep the pressure on Alice."}
        ]
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Day 2 Discussion"
      assert html =~ "Bob keeps steering every vote."
      assert html =~ "Wolf Pack Chat"
      assert html =~ "Night 1"
      assert html =~ "Keep the pressure on Alice."
    end

    test "shows wolf chat while wolf discussion is active" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "alive"}
        },
        phase: "wolf_discussion",
        day_number: 2,
        status: "in_progress",
        active_actor_id: "bob",
        wolf_chat_transcript: [
          %{player: "bob", message: "Keep the pressure on Alice."}
        ]
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Wolf Pack Chat"
      assert html =~ "Keep the pressure on Alice."
    end

    test "shows private meeting transcripts" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "alive"}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        meeting_transcripts: [
          %{
            player_a: "alice",
            player_b: "bob",
            messages: [
              %{player: "alice", message: "If you are good, explain the night kill."},
              %{player: "bob", message: "I was with Mara, not near the square."}
            ]
          }
        ]
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Private Meetings"
      assert html =~ "If you are good, explain the night kill."
      assert html =~ "I was with Mara, not near the square."
    end

    test "renders accusation bubbles with accuser, target, and reason" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "villager", status: "alive"},
          "bob" => %{name: "Bob", role: "werewolf", status: "alive"}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        discussion_transcript: [
          %{
            player: "alice",
            type: "accusation",
            target: "bob",
            reason: "His alibi changed twice."
          }
        ]
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Accuses Bob"
      assert html =~ "Alice accuses Bob. Reason: His alibi changed twice."
    end

    test "renders the current night recap, wander result, and evidence only" do
      world = %{
        players: %{
          "alice" => %{name: "Alice", role: "werewolf", status: "alive"},
          "current_target" => %{name: "Current Target", role: "villager", status: "dead"},
          "stale_target" => %{name: "Stale Target", role: "villager", status: "dead"}
        },
        phase: "day_discussion",
        day_number: 2,
        status: "in_progress",
        night_history: [
          %{
            day: 1,
            player: "alice",
            player_role: "werewolf",
            action: "choose_victim",
            target: "stale_target",
            target_role: "villager",
            successful: true,
            saved: false
          },
          %{
            day: 2,
            player: "alice",
            player_role: "werewolf",
            action: "choose_victim",
            target: "current_target",
            target_role: "villager",
            successful: true,
            saved: false
          }
        ],
        wanderer_results: [
          %{day: 1, wanderer: "stale_target", description: "STALE WANDER RESULT"},
          %{day: 2, wanderer: "Scout", description: "CURRENT WANDER RESULT"}
        ],
        evidence_tokens: [
          %{day: 1, type: "muddy_footprints", clue: "STALE EVIDENCE CLUE"},
          %{day: 2, type: "broken_vial", clue: "CURRENT EVIDENCE CLUE"}
        ]
      }

      html = render_component(&WerewolfBoard.render/1, world: world)

      assert html =~ "Night 2 — What happened in the dark"
      assert html =~ "current_target was killed"
      assert length(String.split(html, "current_target was killed")) == 2
      assert html =~ "Scout"
      assert html =~ "CURRENT WANDER RESULT"
      assert html =~ "CURRENT EVIDENCE CLUE"
      refute html =~ "stale_target was killed"
      refute html =~ "STALE WANDER RESULT"
      refute html =~ "STALE EVIDENCE CLUE"
      refute html =~ "Strange evidence..."
    end
  end

  # ── EventLog ───────────────────────────────────────────────────────

  describe "EventLog" do
    test "renders empty event list" do
      html = render_component(&EventLog.render/1, events: [])

      assert html =~ "No events generated"
    end

    test "renders with a single event" do
      events = [
        %{kind: :make_statement, payload: %{player_id: "alice", statement: "I am innocent!"}}
      ]

      html = render_component(&EventLog.render/1, events: events)

      assert html =~ "make_statement"
      assert html =~ "alice"
      assert html =~ "innocent"
    end

    test "renders with multiple event kinds" do
      events = [
        %{kind: :phase_changed, payload: %{message: "Night falls"}},
        %{kind: :cast_vote, payload: %{player_id: "bob", target_id: "carol"}},
        %{kind: :player_eliminated, payload: %{message: "Carol was eliminated"}}
      ]

      html = render_component(&EventLog.render/1, events: events)

      assert html =~ "phase_changed"
      assert html =~ "cast_vote"
      assert html =~ "player_eliminated"
    end
  end

  # ── PlanHistory ────────────────────────────────────────────────────

  describe "PlanHistory" do
    test "renders empty plan history" do
      html = render_component(&PlanHistory.render/1, plan_history: [])

      assert html =~ "No plans recorded"
    end

    test "renders with plan steps" do
      plan_history = [
        %{summary: "Vote for alice", rationale: "She is suspicious"},
        %{summary: "Gather information"}
      ]

      html = render_component(&PlanHistory.render/1, plan_history: plan_history)

      assert html =~ "Vote for alice"
      assert html =~ "suspicious"
      assert html =~ "Gather information"
    end

    test "renders with string-keyed plan steps" do
      plan_history = [
        %{"summary" => "Attack the goblin", "rationale" => "Lowest HP target"}
      ]

      html = render_component(&PlanHistory.render/1, plan_history: plan_history)

      assert html =~ "Attack the goblin"
      assert html =~ "Lowest HP target"
    end
  end

  # ── RunLog ────────────────────────────────────────────────────────

  describe "RunLog" do
    test "renders current status, recent events, and model traces" do
      state =
        State.new(
          sim_id: "vb_log_test",
          world: %{
            status: "in_progress",
            phase: "operator_turn",
            day_number: 4,
            max_days: 30,
            time_minutes: 615,
            active_actor_id: "operator",
            bank_balance: 512.5,
            cash_in_machine: 18.25
          },
          recent_events: [
            Event.new("supplier_order_placed", %{
              "item_id" => "chips",
              "quantity" => 12
            })
          ],
          plan_history: [
            %{
              summary: "operator used place_supplier_order",
              rationale: "place_supplier_order(item_id=chips, quantity=12) -> order queued",
              meta: %{
                actor: "operator",
                tools: ["place_supplier_order"],
                events: ["supplier_order_placed"]
              }
            }
          ]
        )

      html = render_component(&RunLog.render/1, state: state, running: true)

      assert html =~ "Current Status"
      assert html =~ "4/30"
      assert html =~ "Operator Turn"
      assert html =~ "Running"
      assert html =~ "$512.50"
      assert html =~ "Decision Pressure"
      assert html =~ "Model Decision Trace"
      assert html =~ "operator used place_supplier_order"
      assert html =~ "order queued"
      assert html =~ "Live Event Feed"
      assert html =~ "Supplier Order Placed"
      assert html =~ "12x Chips"
    end

    test "uses the leader world and arena events for artifact-backed VendingBench Arena logs" do
      state =
        State.new(
          sim_id: "vb_arena_log_test",
          world: %{
            mode: "vending_bench_arena",
            status: "complete",
            day_number: 365,
            max_days: 365,
            arena_agents: [
              %{
                id: "alex",
                name: "Alex Market",
                money_balance: 20_298.94,
                world: %{
                  status: "complete",
                  phase: "operator_turn",
                  day_number: 365,
                  max_days: 365,
                  time_minutes: 540,
                  bank_balance: 20_298.94,
                  cash_in_machine: 78.89,
                  pending_deliveries: []
                }
              }
            ],
            arena_events: [
              %{
                kind: "arena_price_war_detected",
                item_id: "candy_bar",
                cheapest_agent_id: "alex",
                expensive_agent_id: "devon",
                spread: 0.3
              }
            ]
          },
          recent_events: []
        )

      html = render_component(&RunLog.render/1, state: state, running: false)

      assert html =~ "365/365"
      assert html =~ "09:00"
      assert html =~ "Operator Turn"
      assert html =~ "$20298.94"
      assert html =~ "$78.89"
      assert html =~ "Arena Price War Detected"
      assert html =~ "Price war on Candy Bar"
      refute html =~ "$0.00"
    end
  end

  # ── MemoryViewer ───────────────────────────────────────────────────

  describe "MemoryViewer" do
    test "renders with nonexistent sim_id (empty memory)" do
      html =
        render_component(&MemoryViewer.render/1,
          sim_id: "nonexistent_sim_test_#{System.unique_integer()}"
        )

      assert html =~ "NO_MEMORY_BANKS_FOUND"
    end
  end
end
