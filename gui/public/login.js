const form = document.getElementById('login-form');
const input = document.getElementById('login-password');
const button = document.getElementById('login-submit');
const result = document.getElementById('login-result');
form.addEventListener('submit', async event => {
  event.preventDefault();
  if (button.disabled) return;
  let password = input.value;
  input.value = '';
  button.disabled = true;
  result.textContent = 'ログインしています…';
  try {
    const response = await fetch('/api/login', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ password })
    });
    password = '';
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'ログインできませんでした');
    const target = new URL('/', location.origin);
    const pair = new URL(location.href).searchParams.get('pair');
    if (['btc_jpy', 'eth_jpy', 'xrp_jpy', 'sol_jpy'].includes(pair)) target.searchParams.set('pair', pair);
    location.replace(target.href);
  } catch (error) { result.textContent = error.message; }
  finally { password = ''; button.disabled = false; }
});
