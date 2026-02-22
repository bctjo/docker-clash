import React from 'react';

import ContentHeader from './ContentHeader';
import s0 from './Home.module.scss';
import TrafficNow from './TrafficNow';

export default function Home() {
  return (
    <div>
      <ContentHeader />
      <div className={s0.root}>
        <TrafficNow />
      </div>
    </div>
  );
}
