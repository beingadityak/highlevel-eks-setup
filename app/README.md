# Node.js Application Information

This Node.js application is a simple REST API which requests for comics (images) from gocomics.com.

This app has following comics available:

1. Garfield (`/random/garfield`)
2. Calvin & Hobbes (`/random/calvinhobbes`)
3. Wizard of Id (`/random/wizardofid`)
4. The Adventures of Business Cat (`/random/businesscat`)
5. Non-sequitr (`/random/nonsequitur`)
6. Peanuts (`/random/peanuts`)

The API is available at `/api` endpoint and you can request a comic by hitting the corresponding comic name endpoint (eg. `/api/random/peanuts`)

You'll get a image link and the date of the comic as the response.

It utilises web scraping for scraping the content and presenting the URL as the response.