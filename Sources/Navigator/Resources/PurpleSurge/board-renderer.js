/**
 * MAIN.JS - UI Director, DOM Bindings, Particle Engine, Event Listeners
 */

/**
 * How one board value should look. A green Gravity Flip coin belongs to the
 * player who dropped it, so it keeps the green face everyone recognises and
 * carries a thin ring in its owner's colour — otherwise there is no way to see
 * whose four in a row it is about to complete.
 * @param {number} value 0 empty, 1 P1, 2 P2, 3 purple, 4 green (P1), 5 green (P2)
 */
/**
 * How one square reads out loud. The board is 42 squares; without this a
 * screen reader announces "Column 3, Row 2" and nothing about what is in it.
 */
function cellLabel(value, row, col) {
  const who = value === 0 ? 'empty' : tokenAppearance(value).label;
  return `Row ${row + 1}, column ${col + 1}: ${who}`;
}

/**
 * Which green coins have already been claimed by their owner.
 *
 * A Gravity Flip coin is green while it is being played — it lands green, and
 * it turns green through the flip. Once the board has settled it is claimed:
 * it takes its owner's colour and keeps a green rim, because from then on it
 * counts towards that player's four in a row and nobody else's. The set is
 * what keeps those two looks apart, and it is emptied at the start of a round.
 */
const claimedGreens = new Set();

function tokenAppearance(value) {
  if (value === 3) return { colorClass: 'purple', symbol: '\u26a1', label: 'Spent Purple Surge token' };
  if (value === 4 || value === 5) {
    const owner = value === 4 ? 1 : 2;
    const label = `Player ${owner}'s Gravity Flip coin`;
    if (!claimedGreens.has(value)) {
      return { colorClass: `green owned-by-p${owner}`, symbol: '\ud83d\udd04', label };
    }
    return {
      colorClass: owner === 1 ? 'red green-claimed' : 'yellow green-claimed',
      symbol: '\ud83d\udd04',
      label: `${label}, now counting as Player ${owner}`,
    };
  }
  if (value === 2) return { colorClass: 'yellow', symbol: '\u25c6', label: 'Player 2' };
  return { colorClass: 'red', symbol: '\u25cf', label: 'Player 1' };
}

class UIDirector {
  initBoardDOM() {
    const gridEl = document.getElementById('board-grid');
    if (!gridEl) return;
    gridEl.innerHTML = '';

    /**
     * The board is something to read, not 42 things to tab through. Every
     * square used to be a focusable button, so reaching the controls below the
     * board meant 42 presses of Tab. The seven column buttons underneath are
     * the way to play by keyboard; the grid just reports what is on it.
     *
     * The rows are real elements because a grid needs rows to be a grid, and
     * they are `display: contents` so the board still lays out as one CSS grid.
     */
    gridEl.setAttribute('role', 'grid');
    gridEl.setAttribute('aria-readonly', 'true');
    gridEl.setAttribute('aria-label', 'Game board, 6 rows by 7 columns');

    for (let r = 0; r < 6; r++) {
      const rowEl = document.createElement('div');
      rowEl.className = 'board-row';
      rowEl.setAttribute('role', 'row');
      rowEl.setAttribute('aria-rowindex', String(r + 1));

      for (let c = 0; c < 7; c++) {
        const cell = document.createElement('div');
        cell.className = 'board-cell';
        cell.dataset.row = r;
        cell.dataset.col = c;
        cell.id = `cell-${r}-${c}`;
        cell.setAttribute('role', 'gridcell');
        cell.setAttribute('aria-colindex', String(c + 1));
        cell.setAttribute('aria-label', cellLabel(0, r, c));

        // Tapping the board is still the quickest way to play with a mouse or
        // a thumb, so that stays.
        cell.addEventListener('click', () => {
          if (window.PSOverlays.ownsInput(document)) return;
          window.gameManager.handleColumnDrop(c);
        });

        rowEl.appendChild(cell);
      }

      gridEl.appendChild(rowEl);
    }
  }
  async animateTokenDrop(col, row, player, isPurple = false, isGreen = false) {
    const cell = document.getElementById(`cell-${row}-${col}`);
    if (!cell) return;

    // Clear any previous token in that cell
    cell.innerHTML = '';

    const piece = document.createElement('div');
    let colorClass = 'red';
    let symbol = '●';

    if (isPurple || player === 3) {
      colorClass = 'purple';
      symbol = '⚡';
    } else if (isGreen || player === 4 || player === 5) {
      const look = tokenAppearance(player === 5 ? 5 : 4);
      colorClass = look.colorClass;
      symbol = look.symbol;
    } else if (player === 2) {
      colorClass = 'yellow';
      symbol = '◆';
    }

    cell.setAttribute('aria-label', cellLabel(isPurple ? 3 : player, row, col));

    piece.className = `token-piece ${colorClass} anim-drop-${row}`;
    piece.innerHTML = `<span class="symbol-glyph">${symbol}</span>`;
    cell.appendChild(piece);

    // Wait for drop animation to finish
    await new Promise(r => setTimeout(r, 420 + row * 40));
    piece.classList.remove(`anim-drop-${row}`);
  }
  async animateRowLaserVaporize(row) {
    const laser = document.getElementById('laser-beam');
    if (laser) {
      // Rows live inside the playfield, which is inset within the chassis art.
      laser.style.top = `calc(var(--grid-top) + ${row} * var(--grid-row-h))`;
      laser.classList.add('active');
    }

    // Add vaporize class to all tokens on that row
    for (let c = 0; c < 7; c++) {
      const cell = document.getElementById(`cell-${row}-${c}`);
      if (cell) {
        cell.classList.add('row-dissolving');
      }
    }

    this.triggerScreenShake();
    await new Promise(r => setTimeout(r, 750));

    // Clear that dissolved row DOM
    for (let c = 0; c < 7; c++) {
      const cell = document.getElementById(`cell-${row}-${c}`);
      if (cell) {
        cell.innerHTML = '';
        cell.classList.remove('row-dissolving');
      }
    }

    if (laser) {
      laser.classList.remove('active');
    }
  }
  async animateGravityCollapse(droppedTiles) {
    // Redraw entire board based on the board engine state with falling animations
    const currentGrid = window.boardEngine.grid;

    for (let r = 0; r < 6; r++) {
      for (let c = 0; c < 7; c++) {
        const cell = document.getElementById(`cell-${r}-${c}`);
        if (!cell) continue;
        cell.innerHTML = '';

        const player = currentGrid[r][c];
        cell.setAttribute('aria-label', cellLabel(player, r, c));
        if (player !== 0) {
          const piece = document.createElement('div');
          const { colorClass, symbol } = tokenAppearance(player);

          // Check if this piece dropped
          const dropped = droppedTiles.find(t => t.toRow === r && t.col === c);
          const shiftClass = dropped ? 'anim-shift-1' : '';

          piece.className = `token-piece ${colorClass} ${shiftClass}`;
          piece.innerHTML = `<span class="symbol-glyph">${symbol}</span>`;
          cell.appendChild(piece);
        }
      }
    }

    await new Promise(r => setTimeout(r, 450));
    // Remove temporary shift classes
    document.querySelectorAll('.token-piece').forEach(el => {
      el.classList.remove('anim-shift-1', 'anim-shift-2');
    });
  }
  async highlightWinLine(line) {
    if (!line || !line.length) return;

    // Pulse winning tokens
    line.forEach(({ r, c }) => {
      const cell = document.getElementById(`cell-${r}-${c}`);
      const piece = cell?.querySelector('.token-piece');
      if (piece) piece.classList.add('winning-token');
    });

    // Draw SVG neon laser line between first and last tokens
    const svg = document.getElementById('win-line-svg');
    if (svg) {
      svg.innerHTML = '';
      const start = line[0];
      const end = line[line.length - 1];

      // The SVG is inset to the playfield (see .win-line-svg), so the 7x6 grid
      // maps onto the whole 700x600 viewBox exactly as it always did.
      const x1 = (start.c + 0.5) * (700 / 7);
      const y1 = (start.r + 0.5) * (600 / 6);
      const x2 = (end.c + 0.5) * (700 / 7);
      const y2 = (end.r + 0.5) * (600 / 6);

      const path = document.createElementNS('http://www.w3.org/2000/svg', 'line');
      path.setAttribute('x1', x1);
      path.setAttribute('y1', y1);
      path.setAttribute('x2', x2);
      path.setAttribute('y2', y2);
      path.setAttribute('class', 'win-line-path');

      svg.appendChild(path);
    }
  }
  clearWinLine() {
    const svg = document.getElementById('win-line-svg');
    if (svg) svg.innerHTML = '';
    document.querySelectorAll('.token-piece.winning-token').forEach(p => {
      p.classList.remove('winning-token');
    });
  }
  renderGrid(grid, lastMoveCoord = null) {
    for (let r = 0; r < 6; r++) {
      for (let c = 0; c < 7; c++) {
        const cell = document.getElementById(`cell-${r}-${c}`);
        if (!cell) continue;
        cell.innerHTML = '';
        cell.classList.remove('last-move-cell');

        const player = grid[r][c];
        cell.setAttribute('aria-label', cellLabel(player, r, c));
        if (player !== 0) {
          const piece = document.createElement('div');
          const { colorClass, symbol } = tokenAppearance(player);

          piece.className = `token-piece ${colorClass}`;
          piece.innerHTML = `<span class="symbol-glyph">${symbol}</span>`;
          cell.appendChild(piece);
        }
      }
    }

    if (lastMoveCoord && lastMoveCoord.row !== null && lastMoveCoord.col !== null) {
      const cell = document.getElementById(`cell-${lastMoveCoord.row}-${lastMoveCoord.col}`);
      if (cell) {
        cell.classList.add('last-move-cell');
      }
    }
  }
  triggerScreenShake() {
    const wrapper = document.getElementById('board-wrapper');
    if (wrapper) {
      wrapper.classList.remove('shake-screen');
      void wrapper.offsetWidth; // Trigger reflow
      wrapper.classList.add('shake-screen');
      setTimeout(() => wrapper.classList.remove('shake-screen'), 450);
    }
  }
  showPowerPreview(col) {
    const gm = window.gameManager;
    const preview = document.getElementById('power-preview');
    const glyph = document.getElementById('power-preview-glyph');
    const wrapper = document.getElementById('board-wrapper');
    if (!preview || !gm?.isSpecialArmed) return;
    if (window.boardEngine.isColumnFull(col)) return this.clearPowerPreview();

    if (gm.specialMode === 'green' || (gm.specialMode === 'mixed' && gm.armedSpecialKind === 'green')) {
      preview.className = 'power-preview is-flip';
      if (glyph) glyph.textContent = '⟳';
      wrapper?.classList.add('flip-preview');
      return;
    }

    const row = window.boardEngine.getAvailableRow(col);
    if (row < 0) return this.clearPowerPreview();
    preview.className = 'power-preview is-surge';
    preview.style.top = `calc(var(--grid-top) + ${row} * var(--grid-row-h))`;
    if (glyph) glyph.textContent = '';
    wrapper?.classList.remove('flip-preview');
  }
  clearPowerPreview() {
    const preview = document.getElementById('power-preview');
    if (preview) preview.className = 'power-preview';
    document.getElementById('board-wrapper')?.classList.remove('flip-preview');
  }
}
