/**
 * Test relayu importuje `ws` względem katalogu `relay/`. W czystym worktree
 * zależność jest instalowana tylko dla macsim, więc podczas testu mapujemy ten
 * jeden specyfikator na jego lokalną instalację — bez zmiany katalogu relay/.
 */
export function resolve(specifier, context, nextResolve) {
  if (specifier === 'ws') {
    return {
      url: new URL('../node_modules/ws/wrapper.mjs', import.meta.url).href,
      shortCircuit: true,
    };
  }
  return nextResolve(specifier, context);
}
