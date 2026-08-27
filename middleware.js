export const config = {
  matcher: '/:path*',
};

export default function middleware(request) {
  const { pathname } = new URL(request.url);
  if (pathname === '/landing.html') return;

  const authHeader = request.headers.get('authorization');

  if (authHeader) {
    const authValue = authHeader.split(' ')[1];
    const [user, pwd] = atob(authValue).split(':');

    if (user === process.env.BASIC_AUTH_USER && pwd === process.env.BASIC_AUTH_PASS) {
      return;
    }
  }

  return new Response('Authentication required.', {
    status: 401,
    headers: {
      'WWW-Authenticate': 'Basic realm="hasib-ai"',
    },
  });
}
