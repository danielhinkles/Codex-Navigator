// Offline presentation only. Native rules and saved moves remain authoritative.
const ui = new UIDirector();
let state = null, busy = false, pending = null;
const send = body => window.webkit.messageHandlers.board.postMessage(body);
window.PSOverlays = { ownsInput: () => busy || !state?.enabled };
window.boardEngine = { grid: [], isColumnFull: c => PSRules.isColumnFull(boardEngine.grid,c), getAvailableRow: c => PSRules.availableRow(boardEngine.grid,c) };
window.gameManager = { specialMode:'purple', isSpecialArmed:false, handleColumnDrop(col) {
  if (busy || !state?.enabled || boardEngine.isColumnFull(col)) return;
  busy = true; ui.clearPowerPreview(); send({type:'move', col, key:state.key});
}};
ui.initBoardDOM();
for(let col=0;col<7;col++) {
 const button=document.createElement('button'); button.textContent=col+1;
 button.setAttribute('aria-label',`Drop in column ${col+1}`);
 button.onclick=()=>gameManager.handleColumnDrop(col);
 button.onmouseenter=button.onfocus=()=>ui.showPowerPreview(col);
 button.onmouseleave=button.onblur=()=>ui.clearPowerPreview();
 document.getElementById('columns').appendChild(button);
}
document.getElementById('board-grid').addEventListener('pointermove',e=> { const cell=e.target.closest('.board-cell'); if(cell&&!busy)ui.showPowerPreview(Number(cell.dataset.col)); });
document.getElementById('board-grid').addEventListener('pointerleave',()=>ui.clearPowerPreview());
async function animateMove(board, move, player) {
 paintHUD(player,move.kind==='surge',true);
 const result = move.kind==='surge' ? PSRules.applyPurpleSurge(board,move.col) : PSRules.applyStandardDrop(board,move.col,player);
 if(!result) return board;
 await ui.animateTokenDrop(move.col,result.landingRow,player,move.kind==='surge');
 if(result.steps) for(const step of result.steps) {
  await ui.animateRowLaserVaporize(step.row); boardEngine.grid=step.board;
  await ui.animateGravityCollapse(step.droppedTiles);
 }
 ui.renderGrid(result.board); return result.board;
}
window.presentBoard = async function(next) {
 if(pending) { pending=next; return; }
 const previous=state;
 const animate=previous && next.puzzle.id===previous.puzzle.id && next.moves.length===previous.moves.length+1 && JSON.stringify(next.moves.slice(0,-1))===JSON.stringify(previous.moves) && !next.reduced;
 state=next; pending=next;
 document.body.toggleAttribute('data-reduced',next.reduced);
 gameManager.isSpecialArmed=next.armed;
 if(next.armed)document.body.dataset.surge='purple'; else delete document.body.dataset.surge;
 ui.clearPowerPreview(); ui.clearWinLine();
 try {
  if(animate) {
   busy=true;
   let board=await animateMove(previous.position.board,next.moves.at(-1),1);
   if(PSPuzzleDefence.standingOn(PSRules,board)===null && next.moves.length<next.puzzle.targetMoves) {
    const reply=PSPuzzleDefence.defenceFor(PSRules,board,{surge:previous.position.opponentSurge,flip:false});
    if(reply) board=await animateMove(board,reply,2);
   }
  }
 } finally {
  boardEngine.grid=next.position.board; ui.renderGrid(boardEngine.grid);
  if(next.position.status==='won')ui.highlightWinLine(next.position.line.map(({row,col})=>({r:row,c:col})));
  document.querySelectorAll('#columns button').forEach((b,c)=>{ b.disabled=!next.enabled||boardEngine.isColumnFull(c); b.setAttribute('aria-label',`${next.armed?'Surge':'Drop'} in column ${c+1}`); });
  paintHUD(1,next.armed,false);
  busy=false; const queued=pending; pending=null;
  send({type:'done',key:next.key});
  if(queued!==next) window.presentBoard(queued);
 }
};
send({type:'ready'});

function paintHUD(turn=1, armed=false, moving=false) {
 const s=state; if(!s)return;
 const over=!moving && s.position.status!=='playing';
 document.body.dataset.turn=String(turn);
 if(armed)document.body.dataset.surge='purple';else delete document.body.dataset.surge;
 const bar=document.getElementById('turn-announcer');
 bar.classList.toggle('is-p2',turn===2); bar.classList.remove('is-theirs');
 bar.classList.toggle('is-armed',armed);bar.classList.toggle('is-over',over);
 document.getElementById('p1-card').classList.toggle('active-turn',turn===1&&!over);
 document.getElementById('p2-card').classList.toggle('active-turn',turn===2&&!over);
 document.getElementById('p1-score').textContent=s.position.surge?'1':'0';
 document.getElementById('p2-score').textContent=s.position.opponentSurge?'1':'0';
 document.getElementById('round-indicator').textContent=`PUZZLE ${String(s.puzzle.id).padStart(3,'0')} · WIN IN ${s.puzzle.targetMoves}`;
 document.getElementById('current-player-label').textContent=over?(s.position.status==='won'?'PUZZLE SOLVED':'TRY ANOTHER ANGLE'):armed?'SURGE ARMED':turn===2?"OPPONENT'S TURN":'YOUR TURN';
 document.getElementById('turn-sub').textContent=over?(s.position.status==='won'?'Next puzzle, or meet a real opponent online.':'Undo or restart to try a different move.'):armed?'Pick a column to clear its landing row.':moving?'Watch the board settle…':'Tap a column to drop your token';
 const power=document.getElementById('btn-use-purple');
 power.disabled=moving||over||!s.enabled||!s.position.surge;
 power.classList.toggle('armed',armed);power.classList.toggle('spent',!s.position.surge);
 document.getElementById('surge-btn-state').textContent=armed?'ARMED':s.position.surge?'CHARGED':'USED';
 document.getElementById('surge-btn-arm').textContent=armed?'ARMED':'ARM';
 document.getElementById('surge-btn-cost').textContent=armed?'Pick a column. That whole row is gone.':'Wipes a whole row. One per puzzle.';
 document.getElementById('surge-hint').textContent='One per puzzle. Arm it, then pick a column.';
 document.getElementById('move-count').textContent=`Move ${s.moves.length} / ${s.puzzle.targetMoves}`;
 document.getElementById('undo').disabled=moving||!s.moves.length||!s.enabled&& !over;
 document.getElementById('restart').disabled=moving||!s.moves.length;
 document.getElementById('next').disabled=moving||s.position.status!=='won';
}
for(const [id,type] of [['btn-use-purple','arm'],['undo','undo'],['restart','restart'],['next','next']])document.getElementById(id).onclick=()=>{if(!busy)send({type,key:state.key});};
for(const id of ['hint','rules'])document.getElementById(id).onclick=()=>{
 const help=document.getElementById('help');const text=id==='hint'?state.puzzle.hint:'Connect four red tokens horizontally, vertically or diagonally. Purple Surge clears its landing row, then the tokens above fall. Win within the puzzle move limit.';
 help.hidden=!help.hidden&&help.textContent===text;help.textContent=text;
};
