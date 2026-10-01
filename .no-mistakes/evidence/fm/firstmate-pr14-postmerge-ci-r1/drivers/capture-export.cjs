const puppeteer = require('./deps/node_modules/puppeteer-core');
const path = require('node:path');
(async () => {
  const browser = await puppeteer.launch({
    executablePath: path.resolve('.calm-validation/chrome.sh'),
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    userDataDir: path.resolve('.calm-validation/screenshot-profile'),
  });
  try {
    const page = await browser.newPage();
    await page.setViewport({width: 1440, height: 1100});
    await page.goto('file:///home/ubuntu/.no-mistakes/evidence/01M3WKBBGW6603Q1A28DA55CZQ/verified/calm-export.html', {waitUntil: 'networkidle0'});
    await page.waitForSelector('.user-message');
    await page.$eval('.user-message', el => el.scrollIntoView({block: 'start'}));
    await page.screenshot({path: '/home/ubuntu/.no-mistakes/evidence/01M3WKBBGW6603Q1A28DA55CZQ/calm-export-conversation.png'});
    console.log('Captured the real Pi export at its first user message.');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode=1; });
