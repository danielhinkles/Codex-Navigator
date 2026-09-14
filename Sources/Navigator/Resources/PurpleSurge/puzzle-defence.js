/**
 * GENERATED FILE — DO NOT EDIT.
 * Built from lib/puzzle-defence.js by scripts/build-browser-defence.mjs.
 * Edit lib/puzzle-defence.js and run `npm run build:rules`.
 */
(function () {
  'use strict';
  /**
   * PUZZLE DEFENCE — the opponent's scripted reply, and the replay that checks
   * a solve.
   *
   * A puzzle promises a win in a fixed number of moves, so the opponent's reply
   * has to be the same every time the same board comes up. This is that reply.
   * It runs in the browser during a puzzle, and again on the server when a
   * solve is reported for Surge Coins: the server replays the player's moves
   * against this exact defence and pays out only if the replay really wins.
   * That is what makes a puzzle solve worth coins — it cannot be claimed, only
   * demonstrated.
   *
   * The rule book is passed in rather than imported, so the same file serves
   * both sides: the server hands it `lib/rules.js`, the browser hands it
   * `window.PSRules`. `scripts/build-browser-defence.mjs` generates the browser
   * copy; only `export function` and `export const` may appear at top level.
   */

  const DEFENCE_VERSION = 2;

  /** Which powers a side holds in a puzzle, read off the puzzle record. */
  function heldBy(puzzle, side) {
    const surge = side === 1 ? puzzle.playerSurge : puzzle.opponentSurge;
    const flip = side === 1 ? puzzle.playerFlip : puzzle.opponentFlip;
    return { surge: Boolean(surge), flip: Boolean(flip) };
  }

  /** Applies one move for `player`. `kind` is 'drop', 'surge' or 'flip'. Null when illegal. */
  function playMove(rules, board, col, player, kind) {
    const copy = rules.cloneBoard(board);
    if (kind === 'surge') return rules.applyPurpleSurge(copy, col)?.board ?? null;
    if (kind === 'flip') return rules.applyGravityFlip(copy, col, player)?.board ?? null;
    return rules.applyStandardDrop(copy, col, player)?.board ?? null;
  }

  /** Who is standing after a move: 1, 2, 'both' or null. */
  function standingOn(rules, board) {
    return rules.winLines(board).winner;
  }

  /**
   * The opponent's defence: the same move every time, for the same board.
   *
   *   1. Take the win if one is there, plainly first, then with a power.
   *   2. Otherwise block any ordinary drop that would win it for the player.
   *   3. Otherwise the centre-most open column.
   *
   * Every puzzle is authored as a forced win, so no defence saves the opponent.
   * What matters is that it is deterministic — a puzzle the player fails must
   * fail the same way when they try it again — and that the server can run it.
   */
  function defenceFor(rules, board, held) {
    const kinds = ['drop'];
    if (held && held.surge) kinds.push('surge');
    if (held && held.flip) kinds.push('flip');

    for (const kind of kinds) {
      for (let col = 0; col < rules.COLS; col += 1) {
        const after = playMove(rules, board, col, 2, kind);
        if (after && standingOn(rules, after) === 2) return { col, kind };
      }
    }

    for (let col = 0; col < rules.COLS; col += 1) {
      const after = playMove(rules, board, col, 2, 'drop');
      if (!after || standingOn(rules, after) !== null) continue;
      let playerStillWins = false;
      for (let c = 0; c < rules.COLS; c += 1) {
        const next = playMove(rules, after, c, 1, 'drop');
        if (next && standingOn(rules, next) === 1) { playerStillWins = true; break; }
      }
      if (!playerStillWins) return { col, kind: 'drop' };
    }

    for (const col of [3, 2, 4, 1, 5, 0, 6]) {
      if (!rules.isColumnFull(board, col)) return { col, kind: 'drop' };
    }
    return null;
  }

  /**
   * Replays a player's moves against the scripted defence.
   *
   * `moves` is what the player did, in order: `[{ col, kind }]`. The replay
   * refuses a power the player does not hold, stops at the advertised move
   * count, and reports whether the board was won inside it. Nothing about the
   * result is taken on trust from the caller.
   */
  function replaySolve(rules, puzzle, moves) {
    let board = rules.cloneBoard(puzzle.grid);
    const mine = heldBy(puzzle, 1);
    const theirs = heldBy(puzzle, 2);
    const limit = puzzle.targetMoves;
    let played = 0;

    for (const move of Array.isArray(moves) ? moves : []) {
      if (played >= limit) return { solved: false, moves: played, reason: 'out_of_moves' };
      const col = Number(move && move.col);
      const kind = move && move.kind === 'surge' ? 'surge' : move && move.kind === 'flip' ? 'flip' : 'drop';
      if (!Number.isInteger(col) || col < 0 || col >= rules.COLS) return { solved: false, moves: played, reason: 'bad_move' };
      if (kind === 'surge' && !mine.surge) return { solved: false, moves: played, reason: 'no_surge' };
      if (kind === 'flip' && !mine.flip) return { solved: false, moves: played, reason: 'no_flip' };

      const after = playMove(rules, board, col, 1, kind);
      if (!after) return { solved: false, moves: played, reason: 'illegal' };
      if (kind === 'surge') mine.surge = false;
      if (kind === 'flip') mine.flip = false;
      played += 1;
      board = after;

      const now = standingOn(rules, board);
      if (now === 1) return { solved: true, moves: played, reason: 'won' };
      if (now !== null) return { solved: false, moves: played, reason: 'lost' };
      if (played >= limit) return { solved: false, moves: played, reason: 'out_of_moves' };

      const reply = defenceFor(rules, board, theirs);
      if (!reply) return { solved: false, moves: played, reason: 'board_full' };
      const replied = playMove(rules, board, reply.col, 2, reply.kind);
      if (!replied) return { solved: false, moves: played, reason: 'board_full' };
      if (reply.kind === 'surge') theirs.surge = false;
      if (reply.kind === 'flip') theirs.flip = false;
      board = replied;
      if (standingOn(rules, board) !== null) return { solved: false, moves: played, reason: 'lost' };
    }

    return { solved: false, moves: played, reason: 'unfinished' };
  }

  window.PSPuzzleDefence = { DEFENCE_VERSION, heldBy, playMove, standingOn, defenceFor, replaySolve };
})();
