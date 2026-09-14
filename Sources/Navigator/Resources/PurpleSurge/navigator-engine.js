// Navigator adapter. The bundled PS rule book and deterministic defence are unchanged.
function navigatorReplay(puzzle, moves) {
  const R = PSRules, D = PSPuzzleDefence;
  let board = R.cloneBoard(puzzle.grid), mine = D.heldBy(puzzle, 1), theirs = D.heldBy(puzzle, 2);
  let status = 'playing', reply = null, count = 0;
  for (const move of moves) {
    reply = null;
    if (status !== 'playing' || !Number.isInteger(move.col) || move.col < 0 || move.col > 6 || !['drop','surge'].includes(move.kind)) throw Error('Invalid move history');
    if (move.kind === 'surge' && !mine.surge) throw Error('Power already used');
    const after = D.playMove(R, board, move.col, 1, move.kind);
    if (!after) throw Error('Full column');
    board = after; count++;
    if (move.kind === 'surge') mine.surge = false;
    let winner = D.standingOn(R, board);
    if (winner === 1) status = 'won';
    else if (winner !== null || count >= puzzle.targetMoves) status = 'retry';
    else {
      reply = D.defenceFor(R, board, theirs);
      if (!reply) status = 'retry';
      else {
        board = D.playMove(R, board, reply.col, 2, reply.kind);
        if (reply.kind === 'surge') theirs.surge = false;
        if (reply.kind === 'flip') theirs.flip = false;
        if (D.standingOn(R, board) !== null) status = 'retry';
      }
    }
  }
  return JSON.stringify({board, surge:mine.surge, opponentSurge:theirs.surge, status, reply:reply ? reply.col : null, line:R.winningLine(board,1) || []});
}
