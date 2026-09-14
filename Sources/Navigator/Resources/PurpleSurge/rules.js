/**
 * GENERATED FILE — DO NOT EDIT.
 * Built from lib/rules.js by scripts/build-browser-rules.mjs.
 * Edit lib/rules.js and run `npm run build:rules`.
 */
(function () {
  'use strict';
  /**
   * PURPLE SURGE — THE RULE BOOK
   *
   * Every rule of the board lives here and nowhere else. The Cloudflare Worker
   * imports this file directly; the offline game in `public/purple-surge` runs
   * `js/rules.js`, which `scripts/build-browser-rules.mjs` generates from this
   * exact file. `tests/rules-sync.test.ts` fails if the generated copy drifts,
   * so the two engines cannot disagree about who won.
   *
   * Board values
   *   0  empty
   *   1  Player 1
   *   2  Player 2
   *   3  a spent Purple Surge token — it belongs to nobody and blocks lines
   *   4  a green Gravity Flip coin played by Player 1
   *   5  a green Gravity Flip coin played by Player 2
   *
   * A green coin belongs to whoever played it, for the rest of the game. It
   * counts towards its owner's four in a row and never towards their opponent's.
   * That ownership is the reason there are two green values instead of one: the
   * board is the only record of the move, so it has to carry the owner.
   *
   * Only `export function` and `export const` declarations may appear at the top
   * level of this file — the browser build refuses anything else.
   */

  const ROWS = 6;
  const COLS = 7;

  const EMPTY = 0;
  const PURPLE = 3;
  const GREEN_P1 = 4;
  const GREEN_P2 = 5;

  /** The green coin value that records `player` as its owner. */
  function greenFor(player) {
    return player === 2 ? GREEN_P2 : GREEN_P1;
  }

  /** Which player a board value counts for. 0 means nobody. */
  function ownerOf(value) {
    if (value === 1 || value === GREEN_P1) return 1;
    if (value === 2 || value === GREEN_P2) return 2;
    return 0;
  }

  function isGreen(value) {
    return value === GREEN_P1 || value === GREEN_P2;
  }

  function createEmptyBoard() {
    return Array.from({ length: ROWS }, () => Array(COLS).fill(EMPTY));
  }

  function cloneBoard(board) {
    return board.map((row) => [...row]);
  }

  /** The row a coin dropped into `col` would land on, or -1 if the column is full. */
  function availableRow(board, col) {
    if (col < 0 || col >= COLS) return -1;
    for (let row = ROWS - 1; row >= 0; row -= 1) {
      if (board[row][col] === EMPTY) return row;
    }
    return -1;
  }

  function isColumnFull(board, col) {
    return availableRow(board, col) === -1;
  }

  function isBoardFull(board) {
    for (let col = 0; col < COLS; col += 1) {
      if (board[0][col] === EMPTY) return false;
    }
    return true;
  }

  /** The four cells that win it for `player`, or null. */
  function winningLine(board, player) {
    const directions = [[0, 1], [1, 0], [1, 1], [1, -1]];
    for (let row = 0; row < ROWS; row += 1) {
      for (let col = 0; col < COLS; col += 1) {
        if (ownerOf(board[row][col]) !== player) continue;
        for (const [rowStep, colStep] of directions) {
          const line = [{ row, col }];
          for (let step = 1; step < 4; step += 1) {
            const nextRow = row + rowStep * step;
            const nextCol = col + colStep * step;
            if (nextRow < 0 || nextRow >= ROWS || nextCol < 0 || nextCol >= COLS) break;
            if (ownerOf(board[nextRow][nextCol]) !== player) break;
            line.push({ row: nextRow, col: nextCol });
          }
          if (line.length === 4) return line;
        }
      }
    }
    return null;
  }

  /**
   * Every four in a row on the board, for both players. `winner` is 'both' when
   * a single move handed each player a line — only a Purple Surge collapse or a
   * Gravity Flip can do that.
   */
  function winLines(board) {
    const p1Lines = [];
    const p2Lines = [];
    const directions = [[0, 1], [1, 0], [1, 1], [1, -1]];
    for (let row = 0; row < ROWS; row += 1) {
      for (let col = 0; col < COLS; col += 1) {
        const player = ownerOf(board[row][col]);
        if (!player) continue;
        for (const [rowStep, colStep] of directions) {
          const line = [{ row, col }];
          for (let step = 1; step < 4; step += 1) {
            const nextRow = row + rowStep * step;
            const nextCol = col + colStep * step;
            if (nextRow < 0 || nextRow >= ROWS || nextCol < 0 || nextCol >= COLS) break;
            if (ownerOf(board[nextRow][nextCol]) !== player) break;
            line.push({ row: nextRow, col: nextCol });
          }
          if (line.length !== 4) continue;
          if (player === 1) p1Lines.push(line);
          else p2Lines.push(line);
        }
      }
    }
    const p1Won = p1Lines.length > 0;
    const p2Won = p2Lines.length > 0;
    return {
      p1Lines,
      p2Lines,
      p1Won,
      p2Won,
      winner: p1Won && p2Won ? 'both' : p1Won ? 1 : p2Won ? 2 : null,
    };
  }

  /** The single winner, or null when nobody or both players have a line. */
  function winnerFor(board) {
    const result = winLines(board);
    if (result.winner === 1) return { player: 1, line: result.p1Lines[0] };
    if (result.winner === 2) return { player: 2, line: result.p2Lines[0] };
    return null;
  }

  /** True when one move gave both players a line at the same instant. */
  function bothConnected(board) {
    const result = winLines(board);
    return result.p1Won && result.p2Won;
  }

  /**
   * Wipes out one row. Everything below it stays put, everything above it drops
   * exactly one layer, and the top row is left empty.
   */
  function dissolveRow(board, row) {
    const next = createEmptyBoard();
    const droppedTiles = [];
    for (let current = ROWS - 1; current > row; current -= 1) {
      for (let col = 0; col < COLS; col += 1) next[current][col] = board[current][col];
    }
    for (let current = row - 1; current >= 0; current -= 1) {
      for (let col = 0; col < COLS; col += 1) {
        const value = board[current][col];
        if (value === EMPTY) continue;
        next[current + 1][col] = value;
        droppedTiles.push({ fromRow: current, toRow: current + 1, col, player: value });
      }
    }
    return { board: next, droppedTiles };
  }

  /** An ordinary coin. Returns null when the column is full. */
  function applyStandardDrop(board, col, player) {
    const landingRow = availableRow(board, col);
    if (landingRow < 0) return null;
    const next = cloneBoard(board);
    next[landingRow][col] = player;
    return { board: next, landingRow };
  }

  /**
   * Picks the next row for a Purple Surge cascade to vaporise.
   *
   * First choice is the row a new coin in the played column would land on, which
   * is what the cascade has always aimed at. That row can be completely empty
   * though, and dissolving an empty row removes nothing and changes nothing — a
   * cascade that keeps choosing it never ends. So an empty row falls through to
   * the highest row that still holds a coin. Every cascade step then removes at
   * least one coin, which is what makes the loop finish.
   *
   * @returns {number} the row to dissolve, or -1 when the board is already bare.
   */
  function cascadeTarget(board, col) {
    const holdsCoins = (row) => board[row].some((value) => value !== EMPTY);
    const landing = availableRow(board, col);
    if (landing !== -1 && holdsCoins(landing)) return landing;
    for (let row = 0; row < ROWS; row += 1) {
      if (holdsCoins(row)) return row;
    }
    return -1;
  }

  /**
   * A Purple Surge. The coin lands, its row is vaporised, and the board settles.
   * If that leaves both players connected at once, another row in the same column
   * dissolves until at most one of them is left standing — the cascade.
   *
   * `steps` carries one entry per dissolve so the offline game can animate the
   * cascade it is about to show, rather than recomputing it.
   *
   * There is no player to pass in: a spent Purple Surge token belongs to nobody,
   * and its row is gone by the time the move is over.
   */
  function applyPurpleSurge(board, col) {
    const landingRow = availableRow(board, col);
    if (landingRow < 0) return null;
    const placed = cloneBoard(board);
    placed[landingRow][col] = PURPLE;

    const steps = [];
    let current = placed;
    let target = landingRow;
    // Each pass removes at least one coin, so the board cannot survive more
    // passes than it has rows.
    for (let pass = 0; pass < ROWS; pass += 1) {
      const collapsed = dissolveRow(current, target);
      steps.push({ row: target, droppedTiles: collapsed.droppedTiles, board: collapsed.board });
      current = collapsed.board;
      if (!bothConnected(current)) break;
      target = cascadeTarget(current, col);
      if (target === -1) break;
    }
    return { board: current, landingRow, steps, placedBoard: placed };
  }

  /**
   * A Gravity Flip. The green coin lands, the whole board turns 180 degrees, and
   * every coin falls into the new bottom of its column.
   */
  function applyGravityFlip(board, col, player) {
    const landingRow = availableRow(board, col);
    if (landingRow < 0) return null;
    const placed = cloneBoard(board);
    placed[landingRow][col] = greenFor(player);

    const inverted = createEmptyBoard();
    for (let row = 0; row < ROWS; row += 1) {
      for (let column = 0; column < COLS; column += 1) {
        const value = placed[row][column];
        if (value !== EMPTY) inverted[ROWS - 1 - row][COLS - 1 - column] = value;
      }
    }

    const settled = createEmptyBoard();
    const droppedTiles = [];
    for (let column = 0; column < COLS; column += 1) {
      let target = ROWS - 1;
      for (let row = ROWS - 1; row >= 0; row -= 1) {
        const value = inverted[row][column];
        if (value === EMPTY) continue;
        settled[target][column] = value;
        droppedTiles.push({ col: column, fromRow: row, toRow: target, player: value });
        target -= 1;
      }
    }
    return { board: settled, landingRow, droppedTiles, placedBoard: placed, invertedBoard: inverted };
  }

  /**
   * The one entry point both engines use for a turn. `special` plus the mode
   * decides which twist is being played; without `special` it is a plain drop.
   */
  function applyMove(board, col, player, special, mode, specialKind) {
    if (!special) return applyStandardDrop(board, col, player);
    if (mode === 'green' || (mode === 'mixed' && specialKind === 'green')) return applyGravityFlip(board, col, player);
    return applyPurpleSurge(board, col);
  }

  window.PSRules = { ROWS, COLS, EMPTY, PURPLE, GREEN_P1, GREEN_P2, greenFor, ownerOf, isGreen, createEmptyBoard, cloneBoard, availableRow, isColumnFull, isBoardFull, winningLine, winLines, winnerFor, bothConnected, dissolveRow, applyStandardDrop, applyPurpleSurge, applyGravityFlip, applyMove };
})();
